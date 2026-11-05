import AppKit
import Common

struct ToggleSplitCommand: Command {
    let args: ToggleSplitCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard let (parent, _) = window.splitParentOrReportError(io) else { return .fail }
        // Not changeOrientation: it flips every ancestor while the opposite-orientation normalization is enabled
        parent.pinOrientation(parent.orientation.opposite)
        return .succ
    }
}
