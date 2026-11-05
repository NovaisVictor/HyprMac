import AppKit
import Common

/// Live preview of a tiling grab (`mouse-grab.live-preview`): the drop or the resize is applied to the tree during
/// the gesture, so the neighbours show where they will end up. Every workspace is frozen right before the preview
/// changes it for the first time, so that cancelling the grab puts the trees back exactly
@MainActor
final class MouseGrabPreview {
    let window: Window
    private let kind: GrabKind
    private let startRect: Rect
    private var mouse: CGPoint
    private var rect: Rect
    private(set) var frozenTrees: [FrozenTilingTree] = []
    private var isActive = true
    /// A single loop at a time, so that a step always sees the layout of the previous one
    private var task: Task<(), any Error>? = nil
    private var lastPreviewedRect: Rect? = nil
    /// The end of the previous grab, which may still be putting its own preview back
    private let previousGrabEnd: Task<(), any Error>?
    private let runMoveStep: MoveStepRunner

    /// ~30 Hz. Each step of a resize preview lays out the whole tiling tree of the workspace
    static let resizeStepInterval: Duration = .milliseconds(33)

    init(
        _ window: Window,
        _ kind: GrabKind,
        startRect: Rect,
        mouse: CGPoint,
        after previousGrabEnd: Task<(), any Error>?,
        runMoveStep: @escaping MoveStepRunner = runMoveStepInLightSession,
    ) {
        self.window = window
        self.runMoveStep = runMoveStep
        self.kind = kind
        self.startRect = startRect
        self.mouse = mouse
        self.rect = startRect
        self.previousGrabEnd = previousGrabEnd
        switch kind {
            case .move:
                // The window is dragged away from its slot. Forget the slot, otherwise the slot would hide the
                // window that the preview has moved into it from the hit-test, and the two windows would swap back
                window.lastAppliedLayoutPhysicalRect = nil
            case .resize:
                // The weights of the whole gesture are computed against the baseline captured at its start
                resetTilingResizeWeightBaseline()
        }
    }

    func update(mouse: CGPoint, rect: Rect) {
        self.mouse = mouse
        self.rect = rect
        if isActive && task == nil {
            task = Task.startUnstructured { @MainActor in
                defer { self.task = nil }
                _ = await self.previousGrabEnd?.result // Only its completion matters, it reports its own failures
                switch self.kind {
                    case .move: try await self.runMoveSteps()
                    case .resize: try await self.runResizeSteps()
                }
            }
        }
    }

    /// The drop and the cancellation must see the tree and the layout of the last step
    func stop() async {
        isActive = false
        await settle()
    }

    func settle() async {
        // A step fails only if its session is cancelled, which leaves nothing half applied
        _ = await task?.result
    }

    /// Cancelling the grab must leave the trees as if it never happened
    func restore() {
        restoreTilingTrees(frozenTrees)
        frozenTrees = []
    }

    private func runMoveSteps() async throws {
        while isActive, resolveMoveStep() != nil {
            if try await !runMoveStep({ self.applyMoveStep() }) { return }
        }
    }

    /// nil when the window is over its own slot or over no window
    private func resolveMoveStep() -> (TilingDropAction, Workspace)? {
        guard window.lifeStatus == .alive, case .tilingContainer = window.windowParentCases else { return nil }
        let targetWorkspace = mouse.monitorApproximation.visibleWorkspace
        let action = resolveTilingDrop(window, at: mouse, targetWorkspace: targetWorkspace)
        if case .none = action { return nil }
        return (action, targetWorkspace)
    }

    private func applyMoveStep() -> Bool {
        // The mouse may have moved while the session started
        guard isActive, let (action, targetWorkspace) = resolveMoveStep(), let sourceWorkspace = window.nodeWorkspace else { return false }
        freeze(sourceWorkspace)
        freeze(targetWorkspace)
        action.apply(to: window)
        return true
    }

    private func runResizeSteps() async throws {
        while isActive, rect != lastPreviewedRect {
            let rect = rect
            lastPreviewedRect = rect
            guard window.lifeStatus == .alive, case .tilingContainer = window.windowParentCases,
                  let workspace = window.nodeWorkspace
            else { return }
            freeze(workspace)
            applyTilingResize(window, from: startRect, to: rect)
            // Weights don't need the model refresh of a session. Only the tiling windows move, which spares the
            // AX requests that the layout of the floating windows makes
            try await workspace.layoutTilingWindows()
            tabBarManager.reconcile()
            try await Task.sleep(for: Self.resizeStepInterval)
        }
    }

    private func freeze(_ workspace: Workspace) {
        if !frozenTrees.contains(where: { $0.workspaceName == workspace.name }) {
            frozenTrees.append(FrozenTilingTree(workspace))
        }
    }
}

/// Applies a step of the move preview and lays out its result. Returns the result of the step:
/// whether it changed the tree. Tests replace it, because sessions need real apps
typealias MoveStepRunner = @MainActor (_ step: @MainActor () -> Bool) async throws -> Bool

/// A session per change of the drop target, not per mouse event. Its layout moves the neighbours
@MainActor
private func runMoveStepInLightSession(_ step: @MainActor () -> Bool) async throws -> Bool {
    guard let token: RunSessionGuard = .isServerEnabled else { return false }
    return try await runLightSession(.mouseGrab, token) { step() }
}
