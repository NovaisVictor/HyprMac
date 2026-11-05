import AppKit
import Common

/// A tab of an accordion. A nested container is represented by its most recent window
struct TabBarItem: Equatable {
    let windowId: OpaqueWindowId
    let appPid: pid_t
    let title: String
    let isActive: Bool
}

/// What a tab bar panel shows. `style` is part of it, so that a config reload re-renders the bars
struct TabBarState: Equatable {
    let frame: Rect
    let items: [TabBarItem]
    let style: TabBarConfig
}

/// The tabs of an accordion: one per inhabited child, in the order of the children.
/// The active tab is the child that the accordion shows
@MainActor
func tabItems(_ container: TilingContainer, title: (Window) -> String) -> [TabBarItem] {
    let active = container.mostRecentInhabitedChild
    return container.inhabitedChildren.compactMap { child -> TabBarItem? in
        guard let window = child.mostRecentInhabitedWindowRecursive else { return nil }
        let windowCount = child.allInhabitedLeafWindowsRecursive.count
        let title = title(window)
        return TabBarItem(
            windowId: window.windowId,
            appPid: window.app.pid,
            // Tells a nested container apart from a single window
            title: child is TilingContainer ? "[\(windowCount)] \(title)" : title,
            isActive: child === active,
        )
    }
}

extension TreeNode {
    /// Unlike ``mostRecentWindowRecursive``, never ends up in a tombstone
    fileprivate var mostRecentInhabitedWindowRecursive: Window? {
        self as? Window ?? mostRecentInhabitedChild?.mostRecentInhabitedWindowRecursive
    }
}

/// The overlay of a single accordion. Tests replace the real panel, see ``TabBarManager/init(makePanel:)``
@MainActor
protocol TabBarPanel: AnyObject {
    /// Moves the panel to the frame of the state and orders it in, if it isn't already
    func show(_ state: TabBarState)
    func hide()
    func close()
}

private let titleRefreshInterval: Duration = .seconds(1)

/// Reconciles one panel per accordion container with the tree, after every layout pass.
/// The bar space itself is reserved by the layout, see ``TilingContainer/lastAppliedTabBarRect``
@MainActor
final class TabBarManager {
    private struct Entry {
        weak var container: TilingContainer?
        let panel: any TabBarPanel
        /// nil while the panel is ordered out
        var shownState: TabBarState?
    }

    private struct CachedTitle {
        let title: String
        let fetchedAt: ContinuousClock.Instant
    }

    private let makePanel: @MainActor () -> any TabBarPanel
    typealias TitleChangeListener = @MainActor (Window, _ title: String) -> Void
    /// Subscribes the manager to title changes while the bars are on (see ``setWindowTitleChangedListener(id:_:)``).
    /// Injected, because the listeners are global and tests use their own managers
    private let observeTitleChanges: (@MainActor (TitleChangeListener?) -> Void)?
    private var isObservingTitleChanges = false
    private var entries: [Entry] = []
    private var titles: [OpaqueWindowId: CachedTitle] = [:]
    /// A single fetch at a time. Titles are fetched with AX requests, which an unresponsive app can make slow
    private(set) var titleRefreshTask: Task<(), Never>? = nil

    init(
        makePanel: @escaping @MainActor () -> any TabBarPanel,
        observeTitleChanges: (@MainActor (TitleChangeListener?) -> Void)? = nil,
    ) {
        self.makePanel = makePanel
        self.observeTitleChanges = observeTitleChanges
    }

    var panelCount: Int { entries.count }

    func isTabBar(at point: CGPoint) -> Bool {
        entries.contains { $0.shownState?.frame.contains(point) == true }
    }

    /// Must run after every layout pass: only the layout knows where the bars are
    func reconcile() {
        let isEnabled = config.tabBar.enabled && TrayMenuModel.shared.isEnabled
        if let observeTitleChanges, isEnabled != isObservingTitleChanges {
            isObservingTitleChanges = isEnabled
            if isEnabled {
                observeTitleChanges { [weak self] window, title in self?.windowTitleDidChange(window.windowId, title: title) }
            } else {
                observeTitleChanges(nil)
            }
        }
        let bars: [(container: TilingContainer, isVisible: Bool)] = isEnabled ? Workspace.all.flatMap(tabBarContainers) : []

        var remaining: [Entry] = []
        for entry in entries {
            if let container = entry.container, bars.contains(where: { $0.container === container }) {
                remaining.append(entry)
            } else {
                entry.panel.close()
            }
        }
        entries = remaining

        var windowsWithTabs: [Window] = []
        for (container, isVisible) in bars {
            let existingIndex = entries.firstIndex { $0.container === container }
            guard isVisible, let frame = container.lastAppliedTabBarRect else {
                // Bars of invisible workspaces are ordered out rather than moved to the corner with the windows
                if let existingIndex, entries[existingIndex].shownState != nil {
                    entries[existingIndex].panel.hide()
                    entries[existingIndex].shownState = nil
                }
                continue
            }
            let index = existingIndex ?? {
                entries.append(Entry(container: container, panel: makePanel(), shownState: nil))
                return entries.count - 1
            }()
            windowsWithTabs += container.inhabitedChildren.compactMap(\.mostRecentInhabitedWindowRecursive)
            let state = TabBarState(frame: frame, items: tabItems(container, title: cachedTitle), style: config.tabBar)
            if entries[index].shownState != state {
                entries[index].panel.show(state)
                entries[index].shownState = state
            }
        }
        let windowIdsWithTabs = windowsWithTabs.map(\.windowId).toSet()
        titles = titles.filter { windowIdsWithTabs.contains($0.key) }
        scheduleTitleRefresh(windowsWithTabs)
    }

    /// Re-renders the tab of the window with its new title, without waiting for the next layout pass.
    /// The title comes from the title change observation, which already re-read it from AX
    func windowTitleDidChange(_ windowId: OpaqueWindowId, title: String) {
        guard titles[windowId] != nil || entries.contains(where: { $0.shownState?.items.contains { $0.windowId == windowId } == true }) else { return }
        titles[windowId] = CachedTitle(title: title, fetchedAt: ContinuousClock.now)
        reconcile()
    }

    func focusTab(_ windowId: OpaqueWindowId) {
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        Task.startUnstructured { @MainActor in
            try await runLightSession(.tabBarClick, token) {
                // The window may have closed since the bar was rendered. The session re-renders the bar anyway
                _ = Window.get(byId: windowId)?.focusWindow()
            }
        }
    }

    /// The window title until the title is fetched, or when the window has none
    private func cachedTitle(_ window: Window) -> String {
        titles[window.windowId]?.title.takeIf { !$0.isEmpty } ?? window.app.name ?? ""
    }

    private func scheduleTitleRefresh(_ windows: [Window]) {
        if titleRefreshTask != nil { return }
        let now = ContinuousClock.now
        let stale = windows.filter { window in titles[window.windowId].map { now - $0.fetchedAt >= titleRefreshInterval } ?? true }
        if stale.isEmpty { return }
        titleRefreshTask = Task.startUnstructured { @MainActor in
            defer { self.titleRefreshTask = nil }
            let result = await Result { try await stale.mapConcurrently { try await $0.getTitle(.cancellable) } }
            switch result {
                case .success(let fetched):
                    let fetchedAt = ContinuousClock.now
                    var isChanged = false
                    for (window, title) in zip(stale, fetched) {
                        isChanged = isChanged || self.titles[window.windowId]?.title != title
                        self.titles[window.windowId] = CachedTitle(title: title, fetchedAt: fetchedAt)
                    }
                    // The task is still set, so the reconcile doesn't schedule another fetch right away
                    if isChanged { self.reconcile() }
                case .failure(is CancellationError): return
                case .failure(let error): die("Illegal error: \(error)")
            }
        }
    }
}

@MainActor let tabBarManager = TabBarManager(
    makePanel: { TabBarNSPanel(onSelect: { tabBarManager.focusTab($0) }) },
    observeTitleChanges: { setWindowTitleChangedListener(id: "tab-bar", $0) },
)

/// The accordions of the workspace that have a bar, and whether the bar must be on the screen
@MainActor
private func tabBarContainers(_ workspace: Workspace) -> [(container: TilingContainer, isVisible: Bool)] {
    // The `fullscreen` window covers the whole workspace. A native fullscreen window lives on its own macOS Space:
    // a bar ordered in now would land on that Space
    let isCovered = workspace.rootTilingContainer.mostRecentWindowRecursive?.isFullscreen == true ||
        globalFocus.windowOrNil.map { $0.nodeWorkspace == workspace && $0.parent is MacosFullscreenWindowsContainer } == true
    let isWorkspaceVisible = workspace.isVisible && !isCovered
    var result: [(container: TilingContainer, isVisible: Bool)] = []
    func visit(_ container: TilingContainer, isShown: Bool) {
        if container.layout == .accordion && !container.inhabitedChildren.isEmpty {
            result.append((container, isWorkspaceVisible && isShown))
        }
        let shownChild = container.layout == .accordion ? container.mostRecentInhabitedChild : nil
        for case let child as TilingContainer in container.children where child.tilingTreeNodeCasesOrDie().isInhabited {
            // The children an accordion doesn't show share the frame of the shown one. Their bars would cover it
            visit(child, isShown: isShown && (shownChild == nil || shownChild === child))
        }
    }
    visit(workspace.rootTilingContainer, isShown: true)
    return result
}
