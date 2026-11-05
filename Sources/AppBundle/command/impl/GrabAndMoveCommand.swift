import AppKit
import Common

struct GrabAndMoveCommand: Command {
    let args: GrabAndMoveCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        .fail(io.err(grabCommandOutsideOfMouseBindingError(.move)))
    }
}
