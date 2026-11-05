import AppKit
import Common

extension Workspace {
    /// Hyprland-like dwindle placement: wraps the most recent tiling window into a new two-children container,
    /// split along the longer side of that window, and returns where the new window must be bound.
    ///
    /// Returns nil when there is nothing to split, so the caller falls back to the sibling placement:
    /// - the workspace has no tiling windows
    /// - the most recent tiling window is the only inhabited child of its parent
    ///   (the parent orientation already decides the split, e.g. the root container with `auto` orientation)
    /// - the parent isn't `tiles`, splitting inside an accordion would break the accordion
    ///
    /// It mutates the tree, so the caller must bind the new window right away, without suspension points in between.
    @MainActor func unbindAndGetBindingDataForDwindleSplit() -> BindingData? {
        guard let mruWindow = rootTilingContainer.mostRecentWindowRecursive,
              let (parent, index) = mruWindow.nearestAliveTilingParent(),
              parent.layout == .tiles,
              parent.inhabitedChildren.count > 1
        else { return nil }

        // Not necessarily mruWindow: the window might be wrapped in a container that is pending to be flattened
        let splitTarget = parent.children[index]
        let orientation = dwindleSplitOrientation(
            splitTarget.lastAppliedLayoutPhysicalRect ?? mruWindow.lastAppliedLayoutPhysicalRect,
            fallback: parent.orientation.opposite,
        )
        return splitTarget.unbindAndWrapInPinnedSplit(orientation, newWindowIndex: INDEX_BIND_LAST)
    }

    /// The placement requested by the preselect command of the most recent tiling window.
    /// Unlike the dwindle placement, it also splits a window that is the only child of its parent (e.g. of the root
    /// container), because the direction is explicit.
    ///
    /// Returns nil, and keeps the preselection, when the most recent tiling window has no preselection
    /// or its parent isn't `tiles` anymore. The preselection is cleared only once it's used.
    ///
    /// It mutates the tree, so the caller must bind the new window right away, without suspension points in between.
    @MainActor func unbindAndGetBindingDataForPreselect() -> BindingData? {
        guard let mruWindow = rootTilingContainer.mostRecentWindowRecursive,
              let direction = mruWindow.preselect,
              let (parent, index) = mruWindow.nearestAliveTilingParent(),
              parent.layout == .tiles
        else { return nil }
        mruWindow.preselect = nil
        // Not necessarily mruWindow: the window might be wrapped in a container that is pending to be flattened
        return parent.children[index].unbindAndWrapInPinnedSplit(
            direction.orientation,
            newWindowIndex: direction.isPositive ? INDEX_BIND_LAST : 0,
        )
    }
}

extension TreeNode {
    /// Replaces the node with a new pinned two-children container that takes the node's weight,
    /// and returns where the new window must be bound inside it
    @MainActor fileprivate func unbindAndWrapInPinnedSplit(_ orientation: Orientation, newWindowIndex: Int) -> BindingData {
        let prevBinding = unbindFromParent()
        let splitContainer = TilingContainer(
            parent: prevBinding.parent,
            adaptiveWeight: prevBinding.adaptiveWeight,
            orientation,
            .tiles,
            index: prevBinding.index,
        )
        splitContainer.hasPinnedOrientation = true
        bind(to: splitContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
        return BindingData(parent: splitContainer, adaptiveWeight: WEIGHT_AUTO, index: newWindowIndex)
    }
}

func dwindleSplitOrientation(_ rect: Rect?, fallback: Orientation) -> Orientation {
    // The rect is unknown until the window is laid out at least once
    guard let rect else { return fallback }
    return rect.width >= rect.height ? .h : .v
}
