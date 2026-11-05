import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let nativeWindowId = ax.containingNativeWindowId()
    let notif = notif as String
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
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
private func moveWithMouse(_ window: Window) async throws {
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            guard let center = try await window.getCenter(.cancellable) else { return }
            rebindFloatingWindowToMonitorUnder(window, center: center)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            currentlyManipulatedWithMouseWindowId = window.windowId
            // The window is dragged away from its slot. Forget the slot, so the hit-test doesn't treat it as a drop target
            window.lastAppliedLayoutPhysicalRect = nil
            let mouseLocation = mouseLocation
            resolveTilingDrop(window, at: mouseLocation, targetWorkspace: mouseLocation.monitorApproximation.visibleWorkspace)
                .apply(to: window)
        case nil: return
    }
}

@MainActor
func rebindFloatingWindowToMonitorUnder(_ window: Window, center: CGPoint) {
    let targetWorkspace = center.monitorApproximation.visibleWorkspace
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

enum TilingDropAction {
    case none
    case swap(with: Window)
    /// Move the window to a different monitor
    case rebind(parent: TilingContainer, index: Int)

    @MainActor
    func apply(to window: Window) {
        switch self {
            case .none: break
            case .swap(let target): swapWindows(mruDominant: window, target)
            case .rebind(let parent, let index): window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
        }
    }
}

/// `targetWorkspace` is the visible workspace of the monitor under `point`
@MainActor
func resolveTilingDrop(_ window: Window, at point: CGPoint, targetWorkspace: Workspace) -> TilingDropAction {
    let swapTarget = point
        .findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
        .takeIf { $0 != window }
    if targetWorkspace != window.nodeWorkspace {
        if let swapTarget,
           let (parent, index) = swapTarget.nearestAliveTilingParent(),
           let targetRect = swapTarget.lastAppliedLayoutPhysicalRect
        {
            let insertionIndex = point.getProjection(parent.orientation) >= targetRect.center.getProjection(parent.orientation)
                ? index + 1
                : index
            return .rebind(parent: parent, index: insertionIndex)
        } else {
            return .rebind(parent: targetWorkspace.rootTilingContainer, index: 0)
        }
    } else if let swapTarget {
        return .swap(with: swapTarget)
    } else {
        return .none
    }
}

@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    if window1 == window2 { return }

    let binding2 = window2.unbindFromParent()
    let binding1 = window1.unbindFromParent()

    window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}

extension CGPoint {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles, .master:
                tree.inhabitedChildren.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentInhabitedChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
