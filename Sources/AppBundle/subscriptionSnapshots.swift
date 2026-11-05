import Common

// A window's workspace can change through many code paths (commands, mouse drags, macOS minimization, normalization,
// on-window-detected callbacks, monitor reconfiguration). Instead of instrumenting every one of them, window-moved and
// monitors-changed are derived by diffing snapshots at the end of refresh sessions, the same way focus events are
// derived from _lastKnownFocus.

/// nil value means that the window is known but doesn't belong to any workspace (e.g. it's minimized)
@MainActor var _lastKnownWindowWorkspaces: [OpaqueWindowId: String?] = [:]
@MainActor private var _lastKnownMonitors: [ServerEventMonitor] = currentServerEventMonitors()

@MainActor func currentServerEventMonitors() -> [ServerEventMonitor] {
    globalSortedMonitorInfos.enumerated().map { ServerEventMonitor(monitorId: $0.offset + 1, monitorName: $0.element.name) }
}

/// window-detected reports the workspace at detection time. Remembering it lets the next diff report a window-moved
/// if on-window-detected callbacks (or anything else) move the window before the refresh session ends
@MainActor func rememberDetectedWindowWorkspace(_ window: Window) {
    _lastKnownWindowWorkspaces.updateValue(window.nodeWorkspace?.name, forKey: window.windowId)
}

/// Pinned windows follow the visible workspace of their monitor. Reporting it would flood the subscribers with
/// window-moved on every workspace switch, while the window doesn't move on the screen.
/// A move that happened earlier in the same session is still reported
@MainActor func rememberPinnedWindowRebind(_ window: Window, from prevWorkspace: String) {
    if _lastKnownWindowWorkspaces[window.windowId] == .some(.some(prevWorkspace)) {
        _lastKnownWindowWorkspaces.updateValue(window.nodeWorkspace?.name, forKey: window.windowId)
    }
}

@MainActor func broadcastWindowAndMonitorSnapshotEvents() {
    for event in diffWindowWorkspaces(MacWindow.allWindows, &_lastKnownWindowWorkspaces) {
        broadcastEvent(event)
    }
    let monitors = currentServerEventMonitors()
    if monitors != _lastKnownMonitors {
        _lastKnownMonitors = monitors
        broadcastEvent(.monitorsChanged(monitors: monitors))
    }
}

/// Windows that are absent from `snapshot` are new: they are recorded silently because window-detected covers them.
/// Windows that are absent from `windows` are closed: they are dropped silently because window-closed covers them.
/// Popups are excluded for consistency with window-detected and window-closed, which don't report them either.
@MainActor func diffWindowWorkspaces(_ windows: [Window], _ snapshot: inout [OpaqueWindowId: String?]) -> [ServerEvent] {
    var newSnapshot: [OpaqueWindowId: String?] = [:]
    var events: [ServerEvent] = []
    for window in windows.sortedBy(\.windowId.rawId) {
        switch window.windowParentCases {
            case .macosPopupWindowsContainer, nil: continue
            case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: break
        }
        let workspace = window.nodeWorkspace?.name
        // updateValue instead of subscript assignment because assigning nil through the subscript would remove the key
        newSnapshot.updateValue(workspace, forKey: window.windowId)
        if let prevWorkspace = snapshot[window.windowId], prevWorkspace != workspace {
            events.append(.windowMoved(
                windowId: window.windowId,
                workspace: workspace,
                prevWorkspace: prevWorkspace,
                appBundleId: window.app.rawAppBundleId,
                appName: window.app.name,
            ))
        }
    }
    snapshot = newSnapshot
    return events
}
