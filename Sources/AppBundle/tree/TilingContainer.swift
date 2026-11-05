import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    private var _layout: Layout
    var lifeStatus: TilingContainerLifeStatus = .alive // todo tighten its visibility
    /// The container keeps its orientation under the opposite-orientation normalization.
    /// Its orientation was chosen explicitly (dwindle new-window-placement, toggle-split, preselect),
    /// so the normalization must not override it
    var hasPinnedOrientation: Bool = false
    /// Share of the container occupied by the master child when `layout == .master`. nil means `master-ratio-percent`
    /// from the config. It's kept across layout changes, so that toggling back to `master` restores it
    var masterRatio: CGFloat? = nil
    /// Overrides `master-placement` of the monitor when `layout == .master`. Set by `layout center_master`,
    /// cleared by `layout master`. Like `masterRatio`, it's kept across layout changes
    var masterPlacement: MasterPlacement? = nil
    /// Where the `[tab-bar]` of the accordion is, set by the last layout pass. nil when the container has no bar
    var lastAppliedTabBarRect: Rect? = nil

    var orientation: Orientation { _orientation }
    var layout: Layout {
        get { _layout }
        set(value) {
            if isDebug && lifeStatus != .alive { die("Can't change layout of not alive TilingContainer") }
            _layout =  value
        }
    }

    func copyFrom(_ other: TilingContainer) {
        self._orientation = other.orientation
        self._layout = other.layout
        self.lifeStatus = other.lifeStatus
        self.hasPinnedOrientation = other.hasPinnedOrientation
        self.masterRatio = other.masterRatio
        self.masterPlacement = other.masterPlacement
    }

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, _ orientation: Orientation, _ layout: Layout, index: Int) {
        self._orientation = orientation
        self._layout = layout
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .h, .tiles, index: index)
    }

    @MainActor
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .v, .tiles, index: index)
    }
}

extension TilingContainer {
    var isRootContainer: Bool { parent is Workspace }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        if orientation == targetOrientation {
            return
        }
        // A container outside of any workspace (e.g. not bound yet) isn't affected by the workspace rules
        let isNormalizationEnabled = nodeWorkspace.map(config.enableNormalizationOppositeOrientationForNestedContainers(for:))
            ?? config.enableNormalizationOppositeOrientationForNestedContainers
        if isNormalizationEnabled {
            parentsWithSelf
                .filterIsInstance(of: TilingContainer.self)
                .forEach { $0._orientation.flip() }
        } else {
            _orientation = targetOrientation
        }
    }

    /// Unlike ``changeOrientation(_:)``, it never flips the ancestors, even if the opposite-orientation normalization
    /// is enabled. The normalization keeps the orientation because it's pinned
    func pinOrientation(_ targetOrientation: Orientation) {
        _orientation = targetOrientation
        hasPinnedOrientation = true
    }

    func normalizeOppositeOrientationForNestedContainersRecursive(parentOrientation: Orientation?) {
        switch lifeStatus {
            case .deadOrInvisible: return
            case .alive where hasPinnedOrientation: break
            case .alive: _orientation = parentOrientation?.opposite ?? orientation
            case .mustBeFlattened: _orientation = parentOrientation ?? orientation
        }
        for child in children {
            (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainersRecursive(parentOrientation: orientation)
        }
    }
}

enum Layout: String {
    case tiles
    case accordion
    /// dwm-like master-stack: the first inhabited child is the master,
    /// the rest of the children are stacked along the opposite orientation
    case master
}

extension String {
    func parseLayout() -> Layout? {
        switch Layout(rawValue: self) {
            case let parsed?: parsed
            case nil where self == "list": .tiles
            case nil: nil
        }
    }
}
