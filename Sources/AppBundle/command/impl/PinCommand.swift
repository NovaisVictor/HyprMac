import AppKit
import Common

struct PinCommand: Command {
    let args: PinCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isPinned
        }
        if newState == window.isPinned {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = newState
                        ? "Already pinned. Tip: use --fail-if-noop to exit with non-zero code"
                        : "Already not pinned. Tip: use --fail-if-noop to exit with non-zero code"
                    return .succ(io.err(msg))
            }
        }
        if !newState {
            // The window stays floating on the workspace it's on
            pinnedWindowIds.remove(window.windowId)
            return .succ
        }
        // A scratchpad window belongs to its home workspace and returns there on hide. A pinned window has no home
        if scratchpadShownWindows[window.windowId] != nil {
            return .fail(io.err("Window \(window.windowId) is shown by scratchpad-toggle. Hide it with scratchpad-toggle before pinning it"))
        }
        switch window.windowParentCases {
            case .tilingContainer, .floatingWindowsContainer: break
            case .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, nil:
                return .fail(io.err("Window \(window.windowId) is minimized, in macOS native fullscreen, a popup, or belongs to a hidden app. It can't be pinned"))
        }
        guard let workspace = window.nodeWorkspace else { return .fail(io.err(bugPrompt())) }
        // A window pinned on an invisible workspace comes to the screen right away, instead of on the next workspace switch
        let targetWorkspace = workspace.isVisible ? workspace : workspace.workspaceMonitorInfo.visibleWorkspace
        let wasTiling = !window.isFloating
        if wasTiling || targetWorkspace != workspace {
            window.bindAsFloatingWindow(to: targetWorkspace)
        }
        // The same as 'layout floating'
        if wasTiling, let size = window.lastFloatingSize { window.setAxFrame(nil, size) }
        pinnedWindowIds.insert(window.windowId)
        return .succ
    }
}
