import AppKit
import Common
import OrderedCollections

private let disclaimer =
    """
    !!! DISCLAIMER !!!
    !!! 'debug-windows' command is not stable API. Please don't rely on the command existence and output format !!!
    !!! The only intended use case is to report bugs about incorrect windows handling !!!
    """

@MainActor private var debugWindowsState: DebugWindowsState = .notRecording
@MainActor private var debugWindowsLog: OrderedDictionary<CombinedWindowId, String> = [:]
private let debugWindowsLimit = 10

struct CombinedWindowId: Hashable {
    // periphery:ignore - Used by Hashable conformance
    var opaque: OpaqueWindowId
    // periphery:ignore - Used by Hashable conformance
    var native: UInt32
}

enum DebugWindowsState {
    case recording
    case notRecording
    case recordingAborted
}

struct DebugWindowsCommand: Command {
    let args: DebugWindowsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        if let windowId = args.windowId {
            guard let window = Window.get(byId: windowId) else {
                return .fail(io.err("Can't find window with the specified window-id: \(windowId)"))
            }
            let nativeWindowId = window.macAppUnsafe.nativeWindowId(of: window.windowId).orDie()
            guard let a = try? await dumpWindowDebugInfo(window, nativeWindowId, .nonCancellable) else { return .fail(io.err(bugPrompt())) }
            io.out(a + "\n")
            io.out(disclaimer)
            return .succ
        }
        switch debugWindowsState {
            case .recording:
                debugWindowsState = .notRecording
                io.out(debugWindowsLog.values.joined(separator: "\n\n"))
                io.out("\n" + disclaimer + "\n")
                io.out("Debug session finished" + "\n")
                debugWindowsLog = [:]
                return .succ
            case .notRecording:
                debugWindowsState = .recording
                debugWindowsLog = [:]
                io.out(
                    """
                    Debug windows session has started
                    1. Focus the problematic window
                    2. Run 'hyprmac debug-windows' once again to finish the session and get the results
                    """,
                )
                // Make sure that the Terminal window that started the recording is recorded first
                guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
                if let window = target.windowOrNil {
                    do {
                        try await debugWindowsIfRecording(window, .nonCancellable)
                    } catch {
                        return .fail(io.err(bugPrompt(String(describing: error))))
                    }
                }
                return .succ
            case .recordingAborted:
                io.out(
                    """
                    Recording of the previous session was aborted after \(debugWindowsLimit) windows has been focused
                    Run the command one more time to start new debug session
                    """,
                )
                debugWindowsState = .notRecording
                debugWindowsLog = [:]
                return .fail
        }
    }
}

@MainActor
private func dumpWindowDebugInfo(_ window: Window, _ nativeWindowId: UInt32, _ cm: CancellationMode) async throws -> String {
    let window = window as! MacWindow
    let appInfoDic = window.macApp.nsApp.bundleURL.flatMap { Bundle.init(url: $0) }?.infoDictionary ?? [:]

    var result: [String: Json] = try await window.dumpAxInfo(cm)

    let windowLevel = try await window.getWindowLevel(cm)
    let windowLevelJson = windowLevel?.toJson() ?? .null
    result["HyprMac.windowLevel"] = windowLevelJson
    result["HyprMac.windowId_opaque"] = .string(window.windowId.description)
    result["HyprMac.windowId_native"] = .int(nativeWindowId)
    result["HyprMac.workspace"] = .stringOrNull(window.nodeWorkspace?.name)
    result["HyprMac.treeNodeParent"] = .string(String(describing: window.parent))
    result["HyprMac.macOS.version"] = .string(ProcessInfo().operatingSystemVersionString) // because built-in apps might behave differently depending on the OS version
    result["HyprMac.App.appBundleId"] = .stringOrNull(window.app.rawAppBundleId)
    result["HyprMac.App.pid"] = .int(Int(window.app.pid))
    result["HyprMac.App.versionShort"] = .stringOrNull(appInfoDic["CFBundleShortVersionString"] as? String)
    result["HyprMac.App.version"] = .stringOrNull(appInfoDic["CFBundleVersion"] as? String)
    result["HyprMac.App.nsApp.activationPolicy"] = .string(window.macApp.nsApp.activationPolicy.prettyDescription)
    result["HyprMac.App.nsApp.execPath"] = .stringOrNull(window.macApp.nsApp.executableURL?.description)
    result["HyprMac.App.nsApp.appBundlePath"] = .stringOrNull(window.macApp.nsApp.bundleURL?.description)
    result["HyprMac.AXApp"] = .dict(try await window.macApp.dumpAppAxInfo(cm))

    let isDialog = try await window.isDialogHeuristic(windowLevel, cm)
    let isWindow = try await window.isWindowHeuristic(windowLevel, cm)
    result["HyprMac.AxUiElementWindowType"] = .string(AxUiElementWindowType.new(isWindow: isWindow, isDialog: { isDialog }).rawValue)
    result["HyprMac.AxUiElementWindowType_isDialogHeuristic"] = .bool(isDialog)

    var matchingCallbacks: [Json] = []
    for callback in config.onWindowDetected where await callback.matches(window) {
        matchingCallbacks.append(callback.debugJson)
    }
    result["HyprMac.on-window-detected"] = .array(matchingCallbacks)

    return JSONEncoder.hyprMacDefault.encodeToString(result).prettyDescription
        .prefixLines(with: "\(window.app.rawAppBundleId ?? "nil-bundle-id").\(window.windowId) ||| ")
}

@MainActor
func debugWindowsIfRecording(_ window: Window, _ cm: CancellationMode) async throws {
    switch debugWindowsState {
        case .recording: break
        case .notRecording, .recordingAborted: return
    }
    if debugWindowsLog.count > debugWindowsLimit {
        debugWindowsState = .recordingAborted
        debugWindowsLog = [:]
    }
    let nativeWindowId = window.macAppUnsafe.nativeWindowId(of: window.windowId).orDie()
    let combinedId = CombinedWindowId(opaque: window.windowId, native: nativeWindowId)
    if debugWindowsLog.keys.contains(combinedId) {
        return
    }
    debugWindowsLog[combinedId] = try await dumpWindowDebugInfo(window, nativeWindowId, cm)
}
