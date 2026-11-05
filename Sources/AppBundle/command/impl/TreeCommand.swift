import AppKit
import Common

struct TreeCommand: Command {
    let args: TreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let focus = globalFocus
        let workspaces: [Workspace] = switch true {
            case args.all: Workspace.all
            case args.focused: [focus.workspace]
            default: [args.workspace.orDie("The parser guarantees one of --all, --focused, --workspace")]
        }
        var dumps: [TreeDumpWorkspace]
        do {
            dumps = try workspaces.map { try TreeDumpWorkspace.snapshot($0, focus: focus) }
            // Titles are fetched after the snapshot, so that windows that close meanwhile can't break its consistency
            try await TreeDumpWorkspace.fetchTitles(&dumps)
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
        if args.json {
            return switch JSONEncoder.hyprMacDefault.encodeToString(dumps) {
                case let json?: .succ(io.out(json))
                case nil: .fail(io.err("Can't encode the tree to JSON"))
            }
        } else {
            return .succ(io.out(dumps.lazy.map { $0.toTextLines() }.joined(separator: [""]).toArray()))
        }
    }
}
