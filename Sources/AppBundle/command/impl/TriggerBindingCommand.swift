import AppKit
import Common

struct TriggerBindingCommand: Command {
    let args: TriggerBindingCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> Int32ExitCode {
        return if let mode = config.modes[args.mode] {
            if let binding = mode.bindings.values.first(where: { $0.descriptionWithKeyNotation == args.binding.val }) {
                // refreshSession is not needed since commands are already run in refreshSession
                await binding.commands.run(env, io)
            } else if let binding = mode.mouseBindings.values.first(where: { $0.descriptionWithKeyNotation == args.binding.val }) {
                // The grab commands of mouse bindings explain that they need a real mouse press
                await binding.commands.run(env, io)
            } else if let binding = mode.modifierTapBindings[args.binding.val] {
                await binding.commands.run(env, io)
            } else {
                .fail(io.err("Binding '\(args.binding.val)' is not presented in mode '\(args.mode)'"))
            }
        } else {
            .fail(io.err("Mode '\(args.mode)' doesn't exist. " +
                    "Available modes: \(config.modes.keys.joined(separator: ","))"))
        }
    }
}
