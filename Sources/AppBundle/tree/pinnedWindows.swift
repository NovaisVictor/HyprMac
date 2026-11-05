import Common

/// Floating windows that stay on the screen on every workspace of their monitor.
///
/// A pinned window always belongs to the visible workspace of its monitor: it's rebound to the new visible workspace
/// whenever the monitor shows another one. So the tree, the focus, `list-windows` and the events agree with the screen,
/// and the window is never hidden in the corner
@MainActor var pinnedWindowIds: Set<OpaqueWindowId> = []

extension Window {
    @MainActor var isPinned: Bool { pinnedWindowIds.contains(windowId) }
}

/// Called once `container` shows `newVisible` instead of `prevVisible`.
/// Every path that changes the visible workspace of a monitor goes through ``WorkspacesContainer/setVisibleWorkspace(_:)``
@MainActor
func rebindPinnedWindows(from prevVisible: Workspace, to newVisible: Workspace) {
    for window in prevVisible.floatingWindowsContainer.children.filterIsInstance(of: Window.self) where window.isPinned {
        rebindPinnedWindow(window, from: prevVisible, to: newVisible)
    }
}

/// The safety net for the paths that make the workspace of a pinned window invisible without switching the visible
/// workspace of its monitor (e.g. a monitor is disconnected, and its workspaces move to the main monitor)
@MainActor
func reconcilePinnedWindows() {
    for windowId in pinnedWindowIds {
        guard let window = Window.get(byId: windowId) else { continue } // MacWindow.garbageCollect forgets it
        switch window.windowParentCases {
            case .floatingWindowsContainer:
                guard let workspace = window.nodeWorkspace, !workspace.isVisible else { continue }
                rebindPinnedWindow(window, from: workspace, to: workspace.workspaceMonitorInfo.visibleWorkspace)
            case .tilingContainer:
                // Only floating windows can be pinned. Something tiled the window (e.g. 'layout tiling')
                pinnedWindowIds.remove(windowId)
            case .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, nil:
                // The window stays pinned. It follows the visible workspace again once it's back on the screen
                continue
        }
    }
}

@MainActor
private func rebindPinnedWindow(_ window: Window, from prevWorkspace: Workspace, to newWorkspace: Workspace) {
    // Least recent, because the window must not take the focus from the most recent window of the new workspace
    window.bindAsLeastRecentChild(to: newWorkspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    rememberPinnedWindowRebind(window, from: prevWorkspace.name)
}
