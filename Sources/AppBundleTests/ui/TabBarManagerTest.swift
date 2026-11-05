@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct TabBarManagerTest {
    private let panels = FakeTabBarPanels()
    private let manager: TabBarManager

    init() {
        setUpWorkspacesForTests()
        config.tabBar.enabled = true
        let panels = panels
        manager = TabBarManager(makePanel: { panels.make() })
    }

    @Test func testTabItems() {
        let root = Workspace.get(byName: name).rootTilingContainer
        root.layout = .accordion
        let window1 = TestWindow.new(id: 1, parent: root)
        let inner = TilingContainer(parent: root, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        let window2 = TestWindow.new(id: 2, parent: inner)
        TestWindow.new(id: 3, parent: inner)
        let window4 = TestWindow.new(id: 4, parent: root)
        _ = window2.focusWindow()

        let title: (Window) -> String = { "w\($0.windowId)" }
        assertEquals(tabItems(root, title: title), [
            TabBarItem(windowId: 1, appPid: 0, title: "w1", isActive: false),
            // A nested container is represented by its most recent window
            TabBarItem(windowId: 2, appPid: 0, title: "[2] w2", isActive: true),
            TabBarItem(windowId: 4, appPid: 0, title: "w4", isActive: false),
        ])

        _ = window4.focusWindow()
        assertEquals(tabItems(root, title: title).map(\.isActive), [false, false, true])
        window4.unbindFromParent()
        window2.unbindFromParent()
        _ = window1.focusWindow()
        assertEquals(tabItems(inner, title: title), [TabBarItem(windowId: 3, appPid: 0, title: "w3", isActive: true)])
    }

    @Test func testCreateUpdateAndRemove() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        let window1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        manager.reconcile()
        assertEquals(manager.panelCount, 1)
        let panel = try #require(panels.made.singleOrNil())
        assertEquals(panel.shown.last?.frame, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 24))
        assertEquals(panel.shown.last?.items.map(\.windowId), [1, 2])
        assertEquals(panel.shown.last?.items.map(\.isActive), [false, true])
        assertTrue(manager.isTabBar(at: CGPoint(x: 100, y: 10)))
        assertFalse(manager.isTabBar(at: CGPoint(x: 100, y: 30)))

        // Nothing changed, nothing to render
        manager.reconcile()
        assertEquals(panel.shown.count, 1)

        _ = window1.focusWindow()
        manager.reconcile()
        assertEquals(panel.shown.count, 2)
        assertEquals(panel.shown.last?.items.map(\.isActive), [true, false])

        root.layout = .tiles
        try await workspace.layoutWorkspace()
        manager.reconcile()
        assertEquals(manager.panelCount, 0)
        assertTrue(panel.isClosed)
        assertFalse(manager.isTabBar(at: CGPoint(x: 100, y: 10)))
    }

    @Test func testDeadContainerLosesItsBar() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let accordion = TilingContainer(parent: root, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST)
        let window2 = TestWindow.new(id: 2, parent: accordion)
        try await workspace.layoutWorkspace()
        manager.reconcile()
        assertEquals(manager.panelCount, 1)

        window2.unbindFromParent()
        accordion.unbindFromParent()
        manager.reconcile()
        assertEquals(manager.panelCount, 0)
        assertEquals(panels.made.map(\.isClosed), [true])
    }

    @Test func testBarsOfInvisibleWorkspacesAreOrderedOut() async throws {
        let workspace1 = Workspace.get(byName: name + "1")
        check(workspace1.focusWorkspace())
        workspace1.rootTilingContainer.layout = .accordion
        TestWindow.new(id: 1, parent: workspace1.rootTilingContainer)
        try await workspace1.layoutWorkspace()
        manager.reconcile()
        let panel = try #require(panels.made.singleOrNil())
        assertTrue(panel.isVisible)

        let workspace2 = Workspace.get(byName: name + "2")
        TestWindow.new(id: 2, parent: workspace2.rootTilingContainer)
        check(workspace2.focusWorkspace())
        manager.reconcile()
        assertFalse(panel.isVisible)
        assertEquals(panel.hideCount, 1)
        assertEquals(manager.panelCount, 1)
        assertFalse(manager.isTabBar(at: CGPoint(x: 100, y: 10)))

        check(workspace1.focusWorkspace())
        manager.reconcile()
        assertTrue(panel.isVisible)
        assertEquals(panels.made.count, 1)
    }

    @Test func testNoPanelForInvisibleWorkspaceUntilShown() {
        let workspace1 = Workspace.get(byName: name + "1")
        workspace1.rootTilingContainer.layout = .accordion
        TestWindow.new(id: 1, parent: workspace1.rootTilingContainer)
        let workspace2 = Workspace.get(byName: name + "2")
        TestWindow.new(id: 2, parent: workspace2.rootTilingContainer)
        check(workspace2.focusWorkspace())
        manager.reconcile()
        assertEquals(manager.panelCount, 0)
    }

    @Test func testAccordionHiddenBehindAnotherTabHasNoVisibleBar() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        let inner = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST)
        let window2 = TestWindow.new(id: 2, parent: inner)
        TestWindow.new(id: 3, parent: inner)
        let window1 = TestWindow.new(id: 1, parent: root, index: 0)
        _ = window1.focusWindow()
        try await workspace.layoutWorkspace()
        manager.reconcile()
        // The inner accordion is under window 1. Its bar would cover window 1
        assertEquals(panels.made.count, 1)
        assertEquals(panels.made.first?.shown.last?.frame.topLeftY, 0)

        _ = window2.focusWindow()
        try await workspace.layoutWorkspace()
        manager.reconcile()
        assertEquals(panels.made.filter(\.isVisible).count, 2)
        assertEquals(panels.made.last?.shown.last?.frame, Rect(topLeftX: 0, topLeftY: 24, width: 1920, height: 24))
    }

    @Test func testFullscreenWindowHidesTheBars() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        let window = TestWindow.new(id: 1, parent: root)
        try await workspace.layoutWorkspace()
        manager.reconcile()
        let panel = try #require(panels.made.singleOrNil())
        assertTrue(panel.isVisible)

        window.isFullscreen = true
        manager.reconcile()
        assertFalse(panel.isVisible)
    }

    @Test func testDisablingRemovesTheBars() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        workspace.rootTilingContainer.layout = .accordion
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        manager.reconcile()
        assertEquals(manager.panelCount, 1)

        config.tabBar.enabled = false
        manager.reconcile()
        assertEquals(manager.panelCount, 0)
        assertEquals(panels.made.map(\.isClosed), [true])
    }

    @Test func testTitleChangeObservation() async throws {
        let panels = FakeTabBarPanels()
        var listener: TabBarManager.TitleChangeListener? = nil
        var registrations = 0
        let manager = TabBarManager(makePanel: { panels.make() }, observeTitleChanges: {
            listener = $0
            registrations += 1
        })
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        let window1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        manager.reconcile()
        manager.reconcile()
        // Subscribed once while the bars are on
        assertEquals(registrations, 1)
        let notify = try #require(listener)

        notify(window1, "New title")
        let panel = try #require(panels.made.singleOrNil())
        assertEquals(panel.shown.last?.items.first { $0.windowId == 1 }?.title, "New title")

        config.tabBar.enabled = false
        manager.reconcile()
        assertEquals(registrations, 2)
        assertNil(listener)
    }

    @Test func testTitles() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        workspace.rootTilingContainer.layout = .accordion
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        manager.reconcile()
        let panel = try #require(panels.made.singleOrNil())
        // The app name until the title is fetched
        assertEquals(panel.shown.last?.items.map(\.title), ["com.victornovais.HyprMac.test-app"])

        await manager.titleRefreshTask?.value
        assertEquals(panel.shown.last?.items.map(\.title), ["TestWindow(1)"])
        assertEquals(panel.shown.count, 2)

        // Fetched less than a second ago
        manager.reconcile()
        assertNil(manager.titleRefreshTask)
    }
}

@MainActor
private final class FakeTabBarPanels {
    private(set) var made: [FakeTabBarPanel] = []

    func make() -> FakeTabBarPanel {
        let panel = FakeTabBarPanel()
        made.append(panel)
        return panel
    }
}

@MainActor
private final class FakeTabBarPanel: TabBarPanel {
    private(set) var shown: [TabBarState] = []
    private(set) var hideCount = 0
    private(set) var isVisible = false
    private(set) var isClosed = false

    func show(_ state: TabBarState) {
        check(!isClosed)
        shown.append(state)
        isVisible = true
    }

    func hide() {
        hideCount += 1
        isVisible = false
    }

    func close() {
        isClosed = true
        isVisible = false
    }
}
