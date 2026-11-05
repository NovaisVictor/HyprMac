import AppKit
import Common

struct PseudotileCommand: Command {
    let args: PseudotileCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isPseudoTiled
        }
        if newState == window.isPseudoTiled {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = newState
                        ? "Already pseudotiled. Tip: use --fail-if-noop to exit with non-zero code"
                        : "Already not pseudotiled. Tip: use --fail-if-noop to exit with non-zero code"
                    return .succ(io.err(msg))
            }
        }
        if newState && window.pseudoSize == nil {
            // The floating size is the size that the app had before the tiling stretched it
            let size: CGSize?
            if let lastFloatingSize = window.lastFloatingSize {
                size = lastFloatingSize
            } else {
                do {
                    size = try await window.getAxSize(.cancellable)
                } catch {
                    return .fail(io.err("Can't get the size of the window: \(error)"))
                }
            }
            guard let size else {
                return .fail(io.err("Can't get the size of the window"))
            }
            window.pseudoSize = size
        }
        window.isPseudoTiled = newState
        return .succ
    }
}
