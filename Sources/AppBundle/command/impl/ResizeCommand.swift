import AppKit
import Common

struct ResizeCommand: Command {
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter {
                return switch ($0.parent as? TilingContainer)?.layout {
                    case .tiles, .master: true
                    case .accordion, nil: false
                }
            }
            .filter {
                guard let parent = $0.parent as? TilingContainer else { return false }
                return switch parent.lifeStatus {
                    case .alive: true
                    case .mustBeFlattened, .deadOrInvisible: false
                }
            }
            ?? []

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
        }
        guard let parent else {
            return .fail(io.err("resize command doesn't support floating windows yet"))
        }
        guard let orientation else { return .fail }
        guard let node else { return .fail }
        if parent.layout == .master {
            check(parent.orientation == orientation)
            return resizeMaster(parent, node, args.units.val, io)
        }
        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        let inhabitedSiblings = parent.inhabitedChildren.filter { $0 != node }
        guard let childDiff = diff.div(inhabitedSiblings.count) else { return .fail }
        for sibling in inhabitedSiblings {
            sibling.setWeight(parent.orientation, sibling.getWeight(parent.orientation) - childDiff)
        }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return .succ
    }
}

/// The master and the stack share the container along its orientation, so resizing either of them moves the boundary
/// between them. The stack children are always evenly split along the opposite orientation.
/// A centered master has a stack on both sides, which always have the same size, so a stack child resizes both of them
@MainActor private func resizeMaster(_ parent: TilingContainer, _ node: TreeNode, _ units: ResizeCmdArgs.Units, _ io: CmdIo) -> BinaryExitCode {
    guard parent.inhabitedChildren.count > 1 else { return .fail }
    guard let containerSize = parent.lastAppliedLayoutVirtualRect?.getDimension(parent.orientation), containerSize > 0 else {
        return .fail(io.err("Can't resize a master container that hasn't been laid out yet"))
    }
    let stackCount: CGFloat = parent.isMasterCentered ? 2 : 1
    // How much the master grows when the resized node grows by one point
    let masterGrowth: CGFloat = node == parent.masterChild ? 1 : -stackCount
    let masterSize = parent.effectiveMasterRatio * containerSize
    let newMasterSize: CGFloat = switch units {
        case .set(let unit): masterGrowth > 0 ? CGFloat(unit) : containerSize - stackCount * CGFloat(unit)
        case .add(let unit): masterSize + masterGrowth * CGFloat(unit)
        case .subtract(let unit): masterSize - masterGrowth * CGFloat(unit)
    }
    parent.masterRatio = (newMasterSize / containerSize).coerce(in: masterRatioRange)
    return .succ
}
