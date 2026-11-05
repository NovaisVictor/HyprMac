import AppKit
import Common

/// Shared by `master-ratio-percent` and the `resize` command, so that neither the master nor the stack collapse
let masterRatioPercentRange: ClosedRange<Int> = 10 ... 90
let masterRatioRange: ClosedRange<CGFloat> = CGFloat(masterRatioPercentRange.lowerBound) / 100 ... CGFloat(masterRatioPercentRange.upperBound) / 100

/// Where the master sits along the container orientation
enum MasterPlacement: String {
    /// Left (top in `v_master`), the stack is on the other side
    case start
    /// In the middle, between two stacks. For ultrawide monitors
    case center
}

/// With fewer children, one of the two stacks of a centered master would be empty,
/// so the master stays at the start instead of leaving a hole on one side
let centeredMasterMinChildren = 3

/// The side of the master that a stack child is on, along the container orientation
enum MasterStackSide {
    /// Right (bottom in `v_master`)
    case positive
    /// Left (top in `v_master`). Only used by a centered master
    case negative
}

/// When the master is centered, the stack children alternate between the two sides, starting with the right one
func masterStackSide(ofStackIndex stackIndex: Int, isCentered: Bool) -> MasterStackSide {
    isCentered && stackIndex % 2 == 1 ? .negative : .positive
}

extension TilingContainer {
    @MainActor
    var effectiveMasterRatio: CGFloat { masterRatio ?? CGFloat(config.masterRatioPercent) / 100 }

    /// The per-container override, or else `master-placement` of the monitor of the container
    @MainActor
    var effectiveMasterPlacement: MasterPlacement {
        if let masterPlacement { return masterPlacement }
        // A container outside of any workspace isn't on any monitor. It isn't laid out, the start is as good as any
        guard let workspace = nodeWorkspace else { return .start }
        return config.masterPlacement.getValue(for: workspace.workspaceMonitorInfo)
    }

    /// Whether the master is actually laid out in the middle. See ``centeredMasterMinChildren``
    @MainActor
    var isMasterCentered: Bool {
        layout == .master && effectiveMasterPlacement == .center && inhabitedChildren.count >= centeredMasterMinChildren
    }

    /// The first inhabited child, or nil if the container is not a `master` container
    var masterChild: TreeNode? {
        layout == .master ? inhabitedChildren.first : nil
    }

    /// The inhabited stack children on the `side` of the master, in the order of the children
    @MainActor
    func inhabitedStackChildren(on side: MasterStackSide) -> [TreeNode] {
        guard masterChild != nil else { return [] }
        let isCentered = isMasterCentered
        return inhabitedChildren.dropFirst().enumerated()
            .filter { masterStackSide(ofStackIndex: $0.offset, isCentered: isCentered) == side }
            .map(\.element)
    }

    /// All the stack children on the `side` touch the master. The most recent one is picked, so that going back
    /// and forth between the master and the stack returns to the same stack child
    @MainActor
    func mostRecentInhabitedStackChild(on side: MasterStackSide) -> TreeNode? {
        let stack = inhabitedStackChildren(on: side)
        return _mruChildren.first { child in stack.contains { $0 === child } } ?? stack.last
    }

    /// Index of the inhabited child that is visually adjacent to the child at `ownIndex` in the `direction`
    ///
    /// In `tiles` and `accordion` layouts, it's the closest inhabited sibling along the container orientation.
    /// In `master` layout, the master and the stacks are adjacent along the container orientation,
    /// and the children of the same stack are adjacent along the opposite orientation.
    @MainActor
    func inhabitedNeighborIndex(of ownIndex: Int, in direction: CardinalDirection) -> Int? {
        switch layout {
            case .tiles, .accordion:
                return orientation == direction.orientation ? inhabitedSiblingIndex(of: ownIndex, in: direction) : nil
            case .master:
                guard let masterIndex = masterChild?.ownIndex(in: .all) else { return nil }
                let directionSide: MasterStackSide = direction.isPositive ? .positive : .negative
                if ownIndex == masterIndex {
                    return direction.orientation == orientation
                        ? mostRecentInhabitedStackChild(on: directionSide)?.ownIndex(in: .all)
                        : nil
                }
                let own = children[ownIndex]
                for side in [MasterStackSide.positive, .negative] {
                    let stack = inhabitedStackChildren(on: side)
                    guard let position = stack.firstIndex(where: { $0 === own }) else { continue }
                    if direction.orientation == orientation {
                        // The stack is on the `side` of the master, so only the opposite direction leads to the master
                        return directionSide == side ? nil : masterIndex
                    }
                    return stack.getOrNil(atIndex: direction.isPositive ? position + 1 : position - 1)?.ownIndex(in: .all)
                }
                return nil
        }
    }
}

struct MasterLayoutFrame {
    /// As if inner gaps were zero
    let virtual: Rect
    /// With inner gaps
    let physical: Rect
}

/// Frames of the inhabited children of a `master` container, relative to the container top-left corner.
///
/// The master takes `ratio` of the container along `orientation`, the rest of the children evenly split the remaining
/// space along the opposite orientation. A single child takes the whole container.
/// With `center` placement (and at least ``centeredMasterMinChildren`` children), the master is in the middle,
/// and the two stacks on its sides evenly share the rest of the container. See ``masterStackSide(ofStackIndex:isCentered:)``
/// Inner gaps are applied only between the children, the same way as in the `tiles` layout.
func masterLayoutFrames(
    width: CGFloat,
    height: CGFloat,
    orientation: Orientation,
    ratio: CGFloat,
    placement: MasterPlacement,
    count: Int,
    innerGaps: ResolvedGaps.Inner,
) -> [MasterLayoutFrame] {
    if count <= 0 { return [] }
    let full = Rect(topLeftX: 0, topLeftY: 0, width: width, height: height)
    if count == 1 { return [MasterLayoutFrame(virtual: full, physical: full)] }

    // "main" is the axis along `orientation` (master vs stack), "cross" is the axis along which the stack is split
    func rect(main: CGFloat, cross: CGFloat, mainSize: CGFloat, crossSize: CGFloat) -> Rect {
        switch orientation {
            case .h: Rect(topLeftX: main, topLeftY: cross, width: mainSize, height: crossSize)
            case .v: Rect(topLeftX: cross, topLeftY: main, width: crossSize, height: mainSize)
        }
    }
    let mainSize = full.getDimension(orientation)
    let crossSize = full.getDimension(orientation.opposite)
    let mainGap = CGFloat(innerGaps.get(orientation))
    let crossGap = CGFloat(innerGaps.get(orientation.opposite))

    let isCentered = placement == .center && count >= centeredMasterMinChildren
    let masterSize = mainSize * ratio.coerce(in: masterRatioRange)
    let stackSize = isCentered ? (mainSize - masterSize) / 2 : mainSize - masterSize
    let masterStart = isCentered ? stackSize : 0
    let stackSides = (0 ..< count - 1).map { masterStackSide(ofStackIndex: $0, isCentered: isCentered) }

    var result = [MasterLayoutFrame(
        virtual: rect(main: masterStart, cross: 0, mainSize: masterSize, crossSize: crossSize),
        physical: rect(
            main: masterStart + (isCentered ? mainGap / 2 : 0),
            cross: 0,
            mainSize: masterSize - (isCentered ? mainGap : mainGap / 2),
            crossSize: crossSize,
        ),
    )]
    var positionsInSides: [MasterStackSide: Int] = [:]
    for side in stackSides {
        let sideCount = stackSides.count { $0 == side }
        let i = positionsInSides[side, default: 0]
        positionsInSides[side] = i + 1
        let main = side == .positive ? masterStart + masterSize : 0
        let stackChildSize = crossSize / CGFloat(sideCount)
        let crossOffset = CGFloat(i) * stackChildSize
        let leadingGap = i == 0 ? 0 : crossGap / 2
        let trailingGap = i == sideCount - 1 ? 0 : crossGap / 2
        result.append(MasterLayoutFrame(
            virtual: rect(main: main, cross: crossOffset, mainSize: stackSize, crossSize: stackChildSize),
            physical: rect(
                main: side == .positive ? main + mainGap / 2 : main,
                cross: crossOffset + leadingGap,
                mainSize: stackSize - mainGap / 2,
                crossSize: stackChildSize - leadingGap - trailingGap,
            ),
        ))
    }
    return result
}
