import AppKit
import Common

/// The tiling tree of a workspace, frozen before a temporary change (e.g. the live preview of a mouse grab)
struct FrozenTilingTree {
    /// Not the workspace itself: an empty invisible workspace is garbage collected, and its tree must still come back
    let workspaceName: String
    let root: FrozenContainer
    /// The child of the workspace that was the most recent one. Rebuilding the tree raises the new root above it
    private let mostRecentWorkspaceChild: TreeNode?

    @MainActor init(_ workspace: Workspace) {
        workspaceName = workspace.name
        root = FrozenContainer(workspace.rootTilingContainer)
        mostRecentWorkspaceChild = workspace.mostRecentChild
    }

    @MainActor fileprivate var workspace: Workspace { Workspace.get(byName: workspaceName) }

    @MainActor fileprivate func restoreWorkspaceMru() {
        if let mostRecentWorkspaceChild, mostRecentWorkspaceChild.parent === workspace {
            mostRecentWorkspaceChild.markAsMostRecentChild()
        }
    }
}

/// Puts the tiling trees back the way they were frozen: shape, weights, layouts, master ratios, dwindle flags and MRU.
/// Unlike the closed windows cache, the windows are expected to be alive, and the trees are restored together, so
/// a window that moved from one of the workspaces to another goes back. A window that is not in any of the trees
/// anymore (e.g. it was closed in the meantime) is skipped. A window that appeared in the meantime is kept
@MainActor func restoreTilingTrees(_ trees: [FrozenTilingTree]) {
    let currentWindows: [(Workspace, Window)] = trees.flatMap { tree in
        let workspace = tree.workspace
        return workspace.rootTilingContainer.allLeafWindowsRecursive.map { (workspace, $0) }
    }
    let windowsById = Dictionary(currentWindows.map { ($0.1.windowId, $0.1) }, uniquingKeysWith: { first, _ in first })
    for tree in trees {
        // Keep the previous root in a variable, so that its windows stay alive until they are bound again
        let prevRoot = tree.workspace.rootTilingContainer
        prevRoot.unbindFromParent()
        restoreContainerRecursive(tree.root, parent: tree.workspace, index: INDEX_BIND_LAST, windowsById)
        tree.restoreWorkspaceMru()
    }
    for (workspace, window) in currentWindows where window.nodeWorkspace == nil {
        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
}

@MainActor
private func restoreContainerRecursive(
    _ frozen: FrozenContainer,
    parent: NonLeafTreeNodeObject,
    index: Int,
    _ windowsById: [OpaqueWindowId: Window],
) {
    let container = TilingContainer(parent: parent, adaptiveWeight: frozen.weight, frozen.orientation, frozen.layout, index: index)
    container.hasPinnedOrientation = frozen.hasPinnedOrientation
    container.masterRatio = frozen.masterRatio
    container.masterPlacement = frozen.masterPlacement
    var restoredChildren: [TreeNode?] = []
    for child in frozen.children {
        switch child {
            case .window(let frozenWindow):
                let window = windowsById[frozenWindow.id]
                if let window {
                    window.bind(to: container, adaptiveWeight: frozenWindow.weight, index: INDEX_BIND_LAST)
                    frozenWindow.restoreState(of: window)
                }
                restoredChildren.append(window)
            case .container(let frozenContainer):
                restoreContainerRecursive(frozenContainer, parent: container, index: INDEX_BIND_LAST, windowsById)
                restoredChildren.append(container.children.last)
        }
    }
    // Binding raises every child. Raise them once more, the least recent first
    for index in frozen.mruChildIndices.reversed() {
        restoredChildren.getOrNil(atIndex: index)??.markAsMostRecentChild()
    }
}
