import AppKit
import Common

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let nativeWindowId = ax.containingNativeWindowId()
    let pid = ax.pid
    bordersOnAxFrameChange(nativeWindowId)
    if let nativeWindowId, isGrabbedWithMouse(nativeWindowId: nativeWindowId) {
        return // Echo of the grab's own frame changes
    }
    if let nativeWindowId, let pid, isAnimationEcho(AnimationEchoKey(pid: pid, nativeWindowId: nativeWindowId)) {
        return // Echo of the frame animator's own writes
    }
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let nativeWindowId,
              let pid,
              let window = Window.get(byNativeId: nativeWindowId, pid: pid),
              try await isManipulatedWithMouse(window)
        else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    // The mouse grab cleans up after itself. A click of another button must not release the grabbed window
    if isMouseGrabActive { return }
    if currentlyManipulatedWithMouseWindowId != nil {
        currentlyManipulatedWithMouseWindowId = nil
        resetTilingResizeWeightBaseline()
        scheduleCancellableCompleteRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
}

@MainActor
func resetTilingResizeWeightBaseline() {
    for workspace in Workspace.all {
        workspace.resetResizeWeightBeforeResizeRecursive()
    }
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")

@MainActor
private func resizeWithMouse(_ window: Window) async throws {
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case nil: return
        case .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            guard let rect = try await window.getAxRect(.cancellable) else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            applyTilingWindowResize(window, from: lastAppliedLayoutRect, to: rect)
            currentlyManipulatedWithMouseWindowId = window.windowId
    }
}

/// Smallest weight (in points) that resizing with the mouse can leave to a window or to its neighbours.
/// Without it, dragging an edge past a neighbour produces zero or negative weights
let minTilingResizeWeight: CGFloat = 50

/// The frame of a pseudotiled window is smaller than its slot, so its new size is the window's own size and must not be
/// translated into weights. The window is centered in its slot again once the gesture is over
@MainActor
func applyTilingWindowResize(_ window: Window, from lastAppliedLayoutRect: Rect, to rect: Rect) {
    if window.isPseudoTiled {
        window.pseudoSize = rect.size
    } else {
        applyTilingResize(window, from: lastAppliedLayoutRect, to: rect)
    }
}

/// Translates the difference between the window's laid out rect and the desired rect into weights.
/// `from` must stay the same during the whole gesture: weights are computed against the baseline captured at the gesture start
@MainActor
func applyTilingResize(_ window: Window, from lastAppliedLayoutRect: Rect, to rect: Rect) {
    let (lParent, lOwnIndex, _) = window.closestParent(hasInhabitedChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil, nil)
    let (dParent, dOwnIndex, _) = window.closestParent(hasInhabitedChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil, nil)
    let (uParent, uOwnIndex, _) = window.closestParent(hasInhabitedChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil, nil)
    let (rParent, rOwnIndex, _) = window.closestParent(hasInhabitedChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil, nil)
    let table: [(CGFloat, TilingContainer?, Int?, Int?)] = [
        (lastAppliedLayoutRect.minX - rect.minX, lParent, 0,                        lOwnIndex),               // Horizontal, to the left of the window
        (rect.maxY - lastAppliedLayoutRect.maxY, dParent, dOwnIndex.map { $0 + 1 }, dParent?.children.count), // Vertical, to the down of the window
        (lastAppliedLayoutRect.minY - rect.minY, uParent, 0,                        uOwnIndex),               // Vertical, to the up of the window
        (rect.maxX - lastAppliedLayoutRect.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count), // Horizontal, to the right of the window
    ]
    for (diff, parent, startIndex, untilIndex) in table {
        if let parent, let startIndex, let untilIndex, untilIndex - startIndex > 0 && abs(diff) > 5 { // 5 pixels should be enough to fight with accumulated floating precision error
            let orientation = parent.orientation

            let growingNodes = window.parentsWithSelf
                .prefix(while: { $0 != parent })
                .filter {
                    let parent = $0.parent as? TilingContainer
                    return parent?.orientation == orientation && parent?.layout == .tiles
                }
            let inhabitedSiblings = (parent.children.slice(startIndex ..< untilIndex) ?? [])
                .filter { $0.tilingTreeNodeCasesOrDie().isInhabited }
            guard let minSiblingWeight = inhabitedSiblings.map({ $0.getWeightBeforeResize(orientation) }).min() else { continue }
            let maxGrowth = max(0, (minSiblingWeight - minTilingResizeWeight) * CGFloat(inhabitedSiblings.count))
            let maxShrink = max(0, (growingNodes.lazy.map { $0.getWeightBeforeResize(orientation) }.min() ?? .infinity) - minTilingResizeWeight)
            let diff = diff.coerce(in: -maxShrink ... maxGrowth)

            for node in growingNodes {
                node.setWeight(orientation, node.getWeightBeforeResize(orientation) + diff)
            }
            guard let siblingDiff = diff.div(inhabitedSiblings.count) else { continue }
            for sibling in inhabitedSiblings {
                sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
            }
        }
    }
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
