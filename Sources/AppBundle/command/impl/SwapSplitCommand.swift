import AppKit
import Common

struct SwapSplitCommand: Command {
    let args: SwapSplitCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard let (parent, _) = window.splitParentOrReportError(io) else { return .fail }
        parent.reverseChildren()
        return .succ
    }
}
