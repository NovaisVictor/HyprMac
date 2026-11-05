import Common

extension Window {
    /// The container that toggle-split, swap-split and preselect act on: the nearest alive tiling parent,
    /// so that a container pending to be flattened is never picked
    @MainActor
    func splitParentOrReportError(_ io: CmdIo) -> (parent: TilingContainer, index: Int)? {
        guard let (parent, index) = nearestAliveTilingParent() else {
            io.err("The window has no tiling parent container. Floating, minimized and macOS fullscreen windows can't be split")
            return nil
        }
        guard parent.layout == .tiles else {
            io.err("The parent container of the window has '\(parent.layout.rawValue)' layout. Only 'tiles' containers can be split")
            return nil
        }
        return (parent, index)
    }
}
