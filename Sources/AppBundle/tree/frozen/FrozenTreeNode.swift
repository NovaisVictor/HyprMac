import AppKit
import Common

enum FrozenTreeNode: Sendable, Equatable {
    case container(FrozenContainer)
    case window(FrozenWindow)
}

struct FrozenContainer: Sendable, Equatable {
    let children: [FrozenTreeNode]
    let layout: Layout
    let orientation: Orientation
    let hasPinnedOrientation: Bool
    let masterRatio: CGFloat?
    let masterPlacement: MasterPlacement?
    let weight: CGFloat
    /// Indices in `children`, the most recent first
    let mruChildIndices: [Int]

    @MainActor init(_ container: TilingContainer) {
        children = container.children.map {
            switch $0.nodeCases {
                case .window(let w): .window(FrozenWindow(w))
                case .tilingContainer(let c): .container(FrozenContainer(c))
                case .workspace,
                     .monitor,
                     .workspacesContainer,
                     .floatingWindowsContainer,
                     .macosMinimizedWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosPopupWindowsContainer:
                    illegalChildParentRelation(child: $0, parent: container)
            }
        }
        layout = container.layout
        orientation = container.orientation
        hasPinnedOrientation = container.hasPinnedOrientation
        masterRatio = container.masterRatio
        masterPlacement = container.masterPlacement
        weight = getWeightOrNil(container) ?? 1
        mruChildIndices = container._mruChildren.compactMap { child in container.children.firstIndex { $0 === child } }
    }
}

struct FrozenWindow: Sendable, Equatable {
    let id: OpaqueWindowId
    let weight: CGFloat
    let isPseudoTiled: Bool
    let pseudoSize: CGSize?
    let isPinned: Bool

    @MainActor init(_ window: Window) {
        id = window.windowId
        weight = getWeightOrNil(window) ?? 1
        isPseudoTiled = window.isPseudoTiled
        pseudoSize = window.pseudoSize
        isPinned = window.isPinned
    }

    /// The restored window may be a new object (e.g. after the lock screen), which lost the state
    @MainActor func restoreState(of window: Window) {
        window.isPseudoTiled = isPseudoTiled
        window.pseudoSize = pseudoSize
        if isPinned {
            pinnedWindowIds.insert(window.windowId)
        } else {
            pinnedWindowIds.remove(window.windowId)
        }
    }
}

@MainActor private func getWeightOrNil(_ node: TreeNode) -> CGFloat? {
    ((node.parent as? TilingContainer)?.orientation).map { node.getWeight($0) }
}
