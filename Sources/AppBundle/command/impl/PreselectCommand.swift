import AppKit
import Common

struct PreselectCommand: Command {
    let args: PreselectCmdArgs
    // The tree isn't changed until the next window is placed
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard let direction = args.arg.val.direction else {
            window.preselect = nil
            return .succ
        }
        guard window.splitParentOrReportError(io) != nil else { return .fail }
        window.preselect = direction
        return .succ
    }
}
