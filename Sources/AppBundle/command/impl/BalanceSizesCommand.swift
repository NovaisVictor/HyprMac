import AppKit
import Common
import Foundation

struct BalanceSizesCommand: Command {
    let args: BalanceSizesCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        balance(target.workspace.rootTilingContainer)
        return .succ
    }
}

@MainActor private func balance(_ parent: TilingContainer) {
    let inhabitedChildren = parent.inhabitedChildren
    let equalWeight: CGFloat? = switch parent.layout {
        case .tiles: CGFloat(inhabitedChildren.sumOfDouble { $0.getWeight(parent.orientation) }).div(inhabitedChildren.count)
        case .accordion, .master: nil
    }
    // The ratio is reset regardless of the current layout, so that it doesn't come back when the layout is toggled
    parent.masterRatio = nil
    for child in inhabitedChildren {
        switch parent.layout {
            case .tiles: child.setWeight(parent.orientation, equalWeight ?? 1)
            case .accordion: break // Do nothing
            case .master: break // The stack is always evenly split
        }
        if let child = child as? TilingContainer {
            balance(child)
        }
    }
}
