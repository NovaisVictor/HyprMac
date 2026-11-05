import Common
import Foundation

/// Bump on breaking changes of the `tree --json` output (removed or renamed keys, changed value types).
/// Adding keys isn't a breaking change
let treeDumpSchemaVersion = 1

/// Nested counterpart of formatToJson, which only supports flat objects
struct TreeDumpWorkspace: Encodable {
    let name: String
    let monitorId: Primitive
    let monitorName: Primitive
    let isFocused: Bool
    let isVisible: Bool
    var rootContainer: TreeDumpContainer
    var floatingWindows: [TreeDumpWindow]
    var macosFullscreenWindows: [TreeDumpWindow]
    var macosMinimizedWindows: [TreeDumpWindow]
    var hiddenAppWindows: [TreeDumpWindow]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema-version"
        case type
        case name
        case monitorId = "monitor-id"
        case monitorName = "monitor-name"
        case isFocused = "is-focused"
        case isVisible = "is-visible"
        case rootContainer = "root-container"
        case floatingWindows = "floating-windows"
        case macosFullscreenWindows = "macos-fullscreen-windows"
        case macosMinimizedWindows = "macos-minimized-windows"
        case hiddenAppWindows = "hidden-app-windows"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(treeDumpSchemaVersion, forKey: .schemaVersion)
        try container.encode("workspace", forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(monitorId, forKey: .monitorId)
        try container.encode(monitorName, forKey: .monitorName)
        try container.encode(isFocused, forKey: .isFocused)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(TreeDumpNode.container(rootContainer), forKey: .rootContainer)
        try container.encode(floatingWindows, forKey: .floatingWindows)
        try container.encode(macosFullscreenWindows, forKey: .macosFullscreenWindows)
        try container.encode(macosMinimizedWindows, forKey: .macosMinimizedWindows)
        try container.encode(hiddenAppWindows, forKey: .hiddenAppWindows)
    }
}

enum TreeDumpNode: Encodable {
    case container(TreeDumpContainer)
    case window(TreeDumpWindow)

    func encode(to encoder: any Encoder) throws {
        switch self {
            case .container(let it): try it.encode(to: encoder)
            case .window(let it): try it.encode(to: encoder)
        }
    }
}

struct TreeDumpContainer: Encodable {
    let layout: String
    let orientation: Orientation
    let weight: CGFloat
    /// Only for the master layout
    let masterRatio: CGFloat?
    /// Only for the master layout. The effective placement: the per-container override or `master-placement` of the monitor
    let masterPlacement: MasterPlacement?
    let hasPinnedOrientation: Bool
    var children: [TreeDumpNode]

    private enum CodingKeys: String, CodingKey {
        case type
        case layout
        case orientation
        case weight
        case masterRatio = "master-ratio"
        case masterPlacement = "master-placement"
        case hasPinnedOrientation = "has-pinned-orientation"
        case children
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("container", forKey: .type)
        try container.encode(layout, forKey: .layout)
        try container.encode(orientation == .h ? "horizontal" : "vertical", forKey: .orientation)
        try container.encode(Double(weight), forKey: .weight)
        // Explicit null rather than an absent key: the key is part of the schema of every container
        try container.encode(masterRatio.map(Double.init), forKey: .masterRatio)
        try container.encode(masterPlacement?.rawValue, forKey: .masterPlacement)
        try container.encode(hasPinnedOrientation, forKey: .hasPinnedOrientation)
        try container.encode(children, forKey: .children)
    }
}

struct TreeDumpWindow: Encodable {
    /// Only to fetch the title after the snapshot. Not encoded
    let window: Window
    let windowId: Primitive
    let appName: Primitive
    let appBundleId: Primitive
    let appPid: Primitive
    /// nil until ``TreeDumpWorkspace/fetchTitles(_:)``
    var title: String?
    let isFocused: Bool
    let isPseudoTiled: Bool
    let isPinned: Bool
    /// Only for tiling windows
    let weight: CGFloat?
    /// Only for windows shown by scratchpad-toggle away from their home workspace
    let scratchpadHomeWorkspace: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case windowId = "window-id"
        case appName = "app-name"
        case appBundleId = "app-bundle-id"
        case appPid = "app-pid"
        case title
        case isFocused = "is-focused"
        case isPseudoTiled = "is-pseudotiled"
        case isPinned = "is-pinned"
        case weight
        case scratchpadHomeWorkspace = "scratchpad-home-workspace"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("window", forKey: .type)
        try container.encode(windowId, forKey: .windowId)
        try container.encode(appName, forKey: .appName)
        try container.encode(appBundleId, forKey: .appBundleId)
        try container.encode(appPid, forKey: .appPid)
        try container.encode(title.orDie("Title wasn't fetched"), forKey: .title)
        try container.encode(isFocused, forKey: .isFocused)
        try container.encode(isPseudoTiled, forKey: .isPseudoTiled)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(weight.map(Double.init), forKey: .weight)
        try container.encodeIfPresent(scratchpadHomeWorkspace, forKey: .scratchpadHomeWorkspace)
    }
}

// MARK: Snapshot

extension TreeDumpWorkspace {
    /// Synchronous, so that the snapshot is consistent. Titles are fetched afterwards, see ``fetchTitles(_:)``
    @MainActor
    static func snapshot(_ workspace: Workspace, focus: LiveFocus) throws -> TreeDumpWorkspace {
        let obj = AeroObj.workspace(workspace)
        // Children of the workspace are read directly rather than through the accessors that create missing
        // containers, so that printing the tree doesn't change it
        func windows<T: NonLeafTreeNodeObject>(_ type: T.Type) throws -> [TreeDumpWindow] {
            try windows(workspace.children.filterIsInstance(of: type).first)
        }
        func windows(_ container: NonLeafTreeNodeObject?) throws -> [TreeDumpWindow] {
            try (container?.children ?? []).filterIsInstance(of: Window.self)
                .filter { $0.lifeStatus.isInhabited }
                .map { try .snapshot($0, focus: focus) }
        }
        return TreeDumpWorkspace(
            name: workspace.name,
            monitorId: try FormatVar.monitor(.monitorId_oneBased).expandFormatVar(obj: obj).get(),
            monitorName: try FormatVar.monitor(.monitorName).expandFormatVar(obj: obj).get(),
            isFocused: focus.workspace == workspace,
            isVisible: workspace.isVisible,
            rootContainer: try .snapshot(workspace.rootTilingContainer, focus: focus),
            floatingWindows: try windows(FloatingWindowsContainer.self),
            macosFullscreenWindows: try windows(MacosFullscreenWindowsContainer.self),
            // Minimized windows don't belong to any workspace. macOS restores them to the focused workspace
            // (see normalizeLayoutReason), so that's where they are reported
            macosMinimizedWindows: focus.workspace == workspace ? try windows(macosMinimizedWindowsContainer) : [],
            hiddenAppWindows: try windows(MacosHiddenAppsWindowsContainer.self),
        )
    }

    private var allWindows: [TreeDumpWindow] {
        rootContainer.allWindows + floatingWindows + macosFullscreenWindows + macosMinimizedWindows + hiddenAppWindows
    }

    @MainActor
    static func fetchTitles(_ workspaces: inout [TreeDumpWorkspace]) async throws {
        var titles: [ObjectIdentifier: String] = [:]
        for window in workspaces.flatMap(\.allWindows).map(\.window) {
            titles[ObjectIdentifier(window)] = try await window.getTitle(.nonCancellable)
        }
        for i in workspaces.indices {
            workspaces[i].applyTitles(titles)
        }
    }

    private mutating func applyTitles(_ titles: [ObjectIdentifier: String]) {
        rootContainer.applyTitles(titles)
        floatingWindows.applyTitles(titles)
        macosFullscreenWindows.applyTitles(titles)
        macosMinimizedWindows.applyTitles(titles)
        hiddenAppWindows.applyTitles(titles)
    }
}

extension TreeDumpContainer {
    @MainActor
    fileprivate static func snapshot(_ container: TilingContainer, focus: LiveFocus) throws -> TreeDumpContainer {
        // The root container has no tiling parent. Its weight along its own orientation is the workspace size
        let weightOrientation = (container.parent as? TilingContainer)?.orientation ?? container.orientation
        return TreeDumpContainer(
            layout: toLayoutString(tc: container),
            orientation: container.orientation,
            weight: container.getWeight(weightOrientation),
            masterRatio: container.layout == .master ? container.effectiveMasterRatio : nil,
            masterPlacement: container.layout == .master ? container.effectiveMasterPlacement : nil,
            hasPinnedOrientation: container.hasPinnedOrientation,
            children: try container.inhabitedChildren.map { child in
                switch child.tilingTreeNodeCasesOrDie() {
                    case .window(let window): .window(try .snapshot(window, focus: focus))
                    case .tilingContainer(let container): .container(try .snapshot(container, focus: focus))
                }
            },
        )
    }

    fileprivate var allWindows: [TreeDumpWindow] {
        children.flatMap { child in
            switch child {
                case .window(let it): [it]
                case .container(let it): it.allWindows
            }
        }
    }

    fileprivate mutating func applyTitles(_ titles: [ObjectIdentifier: String]) {
        for i in children.indices {
            switch children[i] {
                case .window(var it):
                    it.applyTitle(titles)
                    children[i] = .window(it)
                case .container(var it):
                    it.applyTitles(titles)
                    children[i] = .container(it)
            }
        }
    }
}

extension TreeDumpWindow {
    @MainActor
    fileprivate static func snapshot(_ window: Window, focus: LiveFocus) throws -> TreeDumpWindow {
        let obj = AeroObj.window(.withoutTitle(window))
        let weight: CGFloat? = switch window.parent.map({ getChildParentRelation(child: window, parent: $0) }) {
            case .tiling(let parent): window.getWeight(parent.orientation)
            default: nil
        }
        return TreeDumpWindow(
            window: window,
            windowId: try FormatVar.window(.windowId).expandFormatVar(obj: obj).get(),
            appName: try FormatVar.app(.appName).expandFormatVar(obj: obj).get(),
            appBundleId: try FormatVar.app(.appBundleId).expandFormatVar(obj: obj).get(),
            appPid: try FormatVar.app(.appPid).expandFormatVar(obj: obj).get(),
            title: nil,
            isFocused: focus.windowOrNil == window,
            isPseudoTiled: window.isPseudoTiled,
            isPinned: window.isPinned,
            weight: weight,
            scratchpadHomeWorkspace: scratchpadShownWindows[window.windowId]?.workspaceName,
        )
    }

    fileprivate mutating func applyTitle(_ titles: [ObjectIdentifier: String]) {
        title = titles[ObjectIdentifier(window)].orDie("Title wasn't fetched")
    }
}

extension [TreeDumpWindow] {
    fileprivate mutating func applyTitles(_ titles: [ObjectIdentifier: String]) {
        for i in indices { self[i].applyTitle(titles) }
    }
}

// MARK: Text output

extension TreeDumpWorkspace {
    func toTextLines() -> [String] {
        var header = "workspace \(name) (monitor \(monitorId.toString()) \(monitorName.toString().singleQuoted)"
        if isFocused { header += ", focused" }
        if isVisible { header += ", visible" }
        header += ")"
        var sections: [TextTreeNode] = [rootContainer.toTextNode()]
        for (title, windows) in [
            ("floating", floatingWindows),
            ("macos-fullscreen", macosFullscreenWindows),
            ("macos-minimized", macosMinimizedWindows),
            ("hidden-app", hiddenAppWindows),
        ] where !windows.isEmpty {
            sections.append(TextTreeNode(label: title, children: windows.map { TextTreeNode(label: $0.textLabel, children: []) }))
        }
        return [header] + sections.renderTextTree(prefix: "")
    }
}

private struct TextTreeNode {
    let label: String
    let children: [TextTreeNode]
}

extension [TextTreeNode] {
    fileprivate func renderTextTree(prefix: String) -> [String] {
        enumerated().flatMap { (i, node) in
            let isLast = i == count - 1
            return [prefix + (isLast ? "└── " : "├── ") + node.label] +
                node.children.renderTextTree(prefix: prefix + (isLast ? "    " : "│   "))
        }
    }
}

extension TreeDumpContainer {
    fileprivate func toTextNode() -> TextTreeNode {
        var annotations: [String] = []
        if let masterRatio { annotations.append("master-ratio \(Double(masterRatio))") }
        // `start` is the classic master layout, not worth the noise
        if masterPlacement == .center { annotations.append("master-placement center") }
        if hasPinnedOrientation { annotations.append("pinned orientation") }
        let label = annotations.isEmpty ? layout : "\(layout) (\(annotations.joined(separator: ", ")))"
        return TextTreeNode(label: label, children: children.map { child in
            switch child {
                case .window(let it): TextTreeNode(label: it.textLabel, children: [])
                case .container(let it): it.toTextNode()
            }
        })
    }
}

extension TreeDumpWindow {
    fileprivate var textLabel: String {
        var annotations: [String] = []
        if isFocused { annotations.append("focused") }
        if isPseudoTiled { annotations.append("pseudotiled") }
        if isPinned { annotations.append("pinned") }
        if let scratchpadHomeWorkspace { annotations.append("scratchpad home \(scratchpadHomeWorkspace.singleQuoted)") }
        let label = "window \(windowId.toString()) | \(appName.toString()) | \(title.orDie("Title wasn't fetched"))"
        return annotations.isEmpty ? label : "\(label) (\(annotations.joined(separator: ", ")))"
    }
}
