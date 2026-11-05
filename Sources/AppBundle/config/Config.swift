import AppKit
import Common
import HotKey
import OrderedCollections

func getDefaultConfigUrlFromProject() -> URL {
    var url = URL(filePath: #filePath)
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    let projectRoot: URL = url
    return projectRoot.appending(component: "docs/config-examples/default-config.toml")
}

var defaultConfigUrl: URL {
    if isUnitTest {
        return getDefaultConfigUrlFromProject()
    } else {
        return Bundle.main.url(forResource: "default-config", withExtension: "toml")
            // Useful for debug builds that are not app bundles
            ?? getDefaultConfigUrlFromProject()
    }
}
@MainActor let defaultConfig: Config = {
    let parsedConfig = parseConfig(Result { try String(contentsOf: defaultConfigUrl, encoding: .utf8) }.getOrDie())
    if !parsedConfig.errors.isEmpty {
        die("Can't parse default config: \(parsedConfig.errors)")
    }
    return parsedConfig.config
}()
@MainActor var config: Config = defaultConfig // todo move to Ctx?
@MainActor var configUrl: URL = defaultConfigUrl

struct Config: Withable {
    var configVersion: ConfigVersion = ._1
    var _afterLoginCommand: [any Command] = []
    var afterStartupCommand: Shell<any Command> = .empty
    var _indentForNestedContainersWithTheSameOrientation: Void = ()
    var enableNormalizationFlattenContainers: Bool = true
    var _nonEmptyWorkspacesRootContainersLayoutOnStartup: Void = ()
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var newWindowPlacement: NewWindowPlacement = .sibling
    var startAtLogin: Bool = false
    var autoReloadConfig: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordionPadding: Int = 30
    var masterRatioPercent: Int = 55
    var masterNewWindow: MasterNewWindow = .afterFocused
    var masterPlacement: DynamicConfigValue<MasterPlacement> = .constant(.start)
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var persistentWorkspaces: OrderedSet<String> = []
    var execOnWorkspaceChange: [String] = [] // todo deprecate
    var keyMapping = KeyMapping()
    var execConfig: ExecConfig = ExecConfig()
    var focusFollowsMouse: FocusFollowsMouse = FocusFollowsMouse()
    var mouseGrab: MouseGrabConfig = MouseGrabConfig()
    var animations: AnimationsConfig = AnimationsConfig()
    var tabBar: TabBarConfig = TabBarConfig()
    var borders: BordersConfig = BordersConfig()

    var onFocusChanged: Shell<any Command> = .empty
    // var onFocusedWorkspaceChanged: [any Command] = []
    var onFocusedMonitorChanged: Shell<any Command> = .empty

    var gaps: Gaps = .zero
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    /// Per-workspace overrides, keyed by the workspace name. Read them through the `(for: Workspace)` resolvers
    var workspaceRules: [String: WorkspaceRule] = [:]
    var modes: [String: Mode] = [:]
    var onWindowDetected: [WindowDetectedCallback] = []
    var onWindowTitleChanged: [WindowDetectedCallback] = []
    var onModeChanged: Shell<any Command> = .empty
}

struct FocusFollowsMouse: Withable {
    var enabled: Bool = false
}

struct MouseGrabConfig: Withable {
    /// While a tiling window is grabbed, apply the drop/resize to the tree live, so the neighbours show the result
    var livePreview: Bool = false
    /// Deprecated alias of `animations.mouse-grab.duration-ms`. See ``applyDeprecatedMouseGrabAnimationDuration``
    var _animationDurationMs: Int? = nil
    /// Mouse bindings don't grab anything while one of these apps is the frontmost one
    var ignoreAppIds: [String] = []
}

enum ConfigVersion: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case _1 = 1
    case _2 = 2

    static let max = allCases.max().orDie()
    static let min = allCases.min().orDie()
    static func < (lhs: ConfigVersion, rhs: ConfigVersion) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { rawValue.description }
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}

enum NewWindowPlacement: String {
    /// The new tiling window becomes the next sibling of the most recent window
    case sibling
    /// The new tiling window splits the most recent tiling window in two, along its longer side (like Hyprland's dwindle)
    case dwindle
}

/// Where a new tiling window enters a `master` container
enum MasterNewWindow: String {
    /// The next sibling of the most recent window, the same as in the other layouts
    case afterFocused = "after-focused"
    /// Right after the master, the old stack is pushed down
    case stackTop = "stack-top"
    case stackBottom = "stack-bottom"
    /// The new window becomes the master, the old master becomes the top of the stack
    case master
}
