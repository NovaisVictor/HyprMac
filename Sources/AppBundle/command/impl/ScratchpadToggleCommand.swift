import AppKit
import Common

struct ScratchpadToggleCommand: Command {
    let args: ScratchpadToggleCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        // The scratchpad is shown on the workspace the user looks at, regardless of the env context.
        // The same way as summon-workspace targets the focused monitor
        let focusedWorkspace = globalFocus.workspace
        guard let window = resolveScratchpadWindow(focusedWorkspace, io) else { return .fail }
        // A pinned window is already on every workspace of its monitor. It has no home workspace to return to on hide
        if window.isPinned {
            return .fail(io.err("Window \(window.windowId) is pinned. Unpin it with 'pin off' before toggling it as a scratchpad"))
        }
        guard let currentWorkspace = window.nodeWorkspace, window.isConventional else {
            return .fail(io.err("Window \(window.windowId) is minimized, in macOS native fullscreen, a popup, or belongs to a hidden app. It can't be toggled as a scratchpad"))
        }
        switch scratchpadShownWindows[window.windowId] {
            case let home? where currentWorkspace == focusedWorkspace:
                return await hideScratchpad(window, home, from: focusedWorkspace, io)
            case let home?:
                scratchpadShownWindows[window.windowId] = ScratchpadHome(
                    workspaceName: home.workspaceName,
                    wasFloating: home.wasFloating,
                    prevFocusedWindowId: globalFocus.windowOrNil?.windowId,
                )
                // The window stays where it was on the previous workspace. The layout pass carries floating windows over
                window.bindAsFloatingWindow(to: focusedWorkspace)
                return .from(bool: window.focusWindow())
            case nil where currentWorkspace == focusedWorkspace:
                io.err("Window \(window.windowId) already belongs to the focused workspace '\(focusedWorkspace.name)'. Focusing it")
                return .from(bool: window.focusWindow())
            case nil:
                return showScratchpad(window, home: currentWorkspace, on: focusedWorkspace)
        }
    }

    @MainActor
    private func resolveScratchpadWindow(_ focusedWorkspace: Workspace, _ io: CmdIo) -> Window? {
        if let windowId = args.windowId {
            if let window = Window.get(byId: windowId) { return window }
            io.err("Invalid <window-id> \(windowId) passed to --window-id")
            return nil
        }
        let appBundleId = args.appBundleId.orDie("The parser guarantees either --window-id or --app-bundle-id")
        let candidates = Workspace.all
            .flatMap(\.allLeafWindowsRecursive)
            .filter { $0.app.rawAppBundleId == appBundleId && $0.isConventional && !$0.isPinned }
        // There is no global window MRU in HyprMac. The most recent window of its workspace is the closest approximation
        func priority(_ window: Window) -> Int {
            let isOnFocusedWorkspace = window.nodeWorkspace == focusedWorkspace
            return switch (scratchpadShownWindows[window.windowId] != nil, isOnFocusedWorkspace) {
                case (true, true): 0
                case (true, false): 1
                case (false, false): window.nodeWorkspace?.mostRecentWindowRecursive == window ? 2 : 3
                case (false, true): 4
            }
        }
        if let window = candidates.min(by: { priority($0) < priority($1) }) { return window }
        io.err("No window of app '\(appBundleId)' can be toggled as a scratchpad. " +
            "The app isn't running, has no windows, or its windows are pinned, minimized, in macOS native fullscreen or hidden")
        return nil
    }
}

@MainActor
private func showScratchpad(_ window: Window, home: Workspace, on target: Workspace) -> BinaryExitCode {
    let wasFloating = window.isFloating
    scratchpadShownWindows[window.windowId] = ScratchpadHome(
        workspaceName: home.name,
        wasFloating: wasFloating,
        prevFocusedWindowId: globalFocus.windowOrNil?.windowId,
    )
    window.bindAsFloatingWindow(to: target)
    let area = target.workspaceMonitorInfo.visibleRect
    if let frame = scratchpadFrames[window.windowId] {
        window.placeAsScratchpad(frame.toRect(in: area), monitorRect: target.workspaceMonitorInfo.rect)
    } else if !wasFloating {
        window.placeAsScratchpad(centeredScratchpadRect(in: area), monitorRect: target.workspaceMonitorInfo.rect)
    }
    // else: the window keeps the floating frame it had on its home workspace, and doesn't slide: the frame is only
    //       known once unhideFromCorner and layoutFloatingWindow carry it over to the target monitor
    return .from(bool: window.focusWindow())
}

@MainActor
private func hideScratchpad(_ window: Window, _ home: ScratchpadHome, from current: Workspace, _ io: CmdIo) async -> BinaryExitCode {
    let area = current.workspaceMonitorInfo.visibleRect
    let rect: Rect?
    do {
        // A window that is still sliding in is remembered where it lands, not where the slide is now
        if !window.isFloating {
            rect = nil
        } else if let landing = frameAnimator.target(of: window) {
            rect = landing
        } else {
            rect = try await window.getAxRect(.nonCancellable)
        }
    } catch {
        return .fail(io.err(bugPrompt()))
    }
    // The window could have been closed and garbage collected during the suspension point above
    guard scratchpadShownWindows.removeValue(forKey: window.windowId) != nil else {
        return .fail(io.err("Window \(window.windowId) was closed"))
    }
    if let rect { scratchpadFrames[window.windowId] = ScratchpadFrame(rect, relativeTo: area) }

    let homeWorkspace = Workspace.get(byName: home.workspaceName)
    if home.wasFloating {
        window.bindAsFloatingWindow(to: homeWorkspace)
    } else {
        do {
            try await window.relayoutWindow(on: homeWorkspace, .nonCancellable, forceTile: true)
        } catch {
            return .fail(io.err(bugPrompt()))
        }
    }
    // The window already belongs to its home workspace, so the focus and the commands that follow see the final tree.
    // It's only hidden in the corner once it's out of the screen: the hide loop skips animating windows.
    // A visible home workspace lays the window out right away, which would cancel the slide anyway
    if let rect, let (style, direction) = scratchpadSlide, !homeWorkspace.isVisible {
        let monitorRect = current.workspaceMonitorInfo.rect
        if home.wasFloating { window.rememberFrameToUnhide(rect, monitorRect: monitorRect) }
        frameAnimator.animate(window, from: rect, to: rect.pushedOut(of: monitorRect, direction), style) {
            onScratchpadSlideOutLanded()
        }
    }

    if let prevFocused = home.prevFocusedWindowId.flatMap({ Window.get(byId: $0) }), prevFocused.nodeWorkspace == current {
        return .from(bool: prevFocused.focusWindow())
    }
    return .from(bool: current.focusWorkspace())
}

private func centeredScratchpadRect(in area: Rect) -> Rect {
    area.centered(CGSize(width: area.width * 2 / 3, height: area.height * 2 / 3))
}

extension Window {
    fileprivate var isConventional: Bool {
        switch windowParentCases {
            case .tilingContainer, .floatingWindowsContainer: true
            case .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, nil: false
        }
    }

    /// Slides the window in from outside of `monitorRect` when the scratchpad animation is enabled.
    /// A window that is still sliding out turns back from where it is
    @MainActor
    fileprivate func placeAsScratchpad(_ rect: Rect, monitorRect: Rect) {
        forgetHiddenInCornerPosition()
        lastFloatingSize = rect.size
        if let (style, direction) = scratchpadSlide {
            let offScreen = rect.pushedOut(of: monitorRect, direction)
            // The slide only writes the position while the size doesn't change. So the size is applied before it starts
            if frameAnimator.target(of: self) == nil { setAxFrame(offScreen.topLeftCorner, offScreen.size) }
            frameAnimator.animate(self, from: offScreen, to: rect, style)
        } else {
            setAxFrame(rect.topLeftCorner, rect.size)
        }
    }
}
