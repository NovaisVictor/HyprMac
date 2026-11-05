import AppKit
import Common

// Where a newly detected (or re-laid out) window enters the tree: popups, dialogs and the tiling placements
// (preselect, sibling, dwindle, master-new-window). Kept apart from MacWindow because the tiling placement policies keep growing

extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws {
        let parentKind: NewWindowParentKind = forceTile
            ? .tiling
            : try await getNewWindowParentKind(self.asMacWindow().windowId, self.asMacWindow().macApp, cm)
        let data = parentKind.unbindAndGetBindingData(workspace, window: self)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}

enum NewWindowParentKind {
    case popup, floating, tiling

    // The function is unsafe. It leaves the window in unbound state.
    // It must be called right before the bind, without suspension points in between,
    // because the dwindle placement mutates the tree (see unbindAndGetBindingDataForDwindleSplit)
    @MainActor
    func unbindAndGetBindingData(_ workspace: Workspace, window: Window?) -> BindingData {
        switch self {
            case .popup: BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .floating: BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .tiling: unbindAndGetBindingDataForNewTilingWindow(workspace, window: window)
        }
    }

    /// nil for popups because on-window-detected callbacks don't run for them
    func initialPlacement(_ workspace: Workspace) -> DetectedWindowPlacement? {
        switch self {
            case .popup: nil
            case .floating: DetectedWindowPlacement(workspace: workspace, kind: .floating)
            case .tiling: DetectedWindowPlacement(workspace: workspace, kind: .newTilingWindow)
        }
    }
}

extension DetectedWindowPlacement {
    // The function is unsafe for the same reason as NewWindowParentKind.unbindAndGetBindingData
    @MainActor
    func unbindAndGetBindingData() -> BindingData {
        switch kind {
            case .floating: BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .newTilingWindow: unbindAndGetBindingDataForNewTilingWindow(workspace, window: nil)
            case .appendedToRootTilingContainer: BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
    }
}

@MainActor
func getNewWindowParentKind(_ windowId: OpaqueWindowId, _ macApp: MacApp, _ cm: CancellationMode) async throws -> NewWindowParentKind {
    let windowLevel = try await macApp.getWindowLevel(windowId, cm)
    return switch try await macApp.getAxUiElementWindowType(windowId, windowLevel, cm) {
        case .popup: .popup
        case .dialog: .floating
        case .window: .tiling
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?) -> BindingData {
    window?.unbindFromParent() // It's important to unbind to get correct data from below
    // Before the placement policy: an explicit preselection wins over both 'sibling' and 'dwindle'
    if let data = workspace.unbindAndGetBindingDataForPreselect() {
        return data
    }
    if config.newWindowPlacement(for: workspace) == .dwindle, let data = workspace.unbindAndGetBindingDataForDwindleSplit() {
        return data
    }
    if let (tilingParent, index) = workspace.mostRecentWindowRecursive?.nearestAliveTilingParent() {
        let masterIndex = tilingParent.newWindowIndexInMaster(config.masterNewWindow(for: workspace))
        return BindingData(parent: tilingParent, adaptiveWeight: WEIGHT_AUTO, index: masterIndex ?? index + 1)
    } else {
        return BindingData(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
    }
}

extension TilingContainer {
    /// Index for a new window by `master-new-window`. nil means the generic sibling placement
    fileprivate func newWindowIndexInMaster(_ placement: MasterNewWindow) -> Int? {
        guard let masterIndex = masterChild?.ownIndex(in: .all) else { return nil }
        return switch placement {
            case .afterFocused: nil
            case .master: masterIndex
            case .stackTop: masterIndex + 1
            case .stackBottom: INDEX_BIND_LAST
        }
    }
}
