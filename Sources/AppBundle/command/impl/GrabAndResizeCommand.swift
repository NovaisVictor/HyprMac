import AppKit
import Common

struct GrabAndResizeCommand: Command {
    let args: GrabAndResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        .fail(io.err(grabCommandOutsideOfMouseBindingError(.resize)))
    }
}
