@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct TabBarLayoutTest {
    init() {
        setUpWorkspacesForTests()
        config.tabBar.enabled = true
    }

    @Test func testSingleAccordionReservesTheBar() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        assertEquals(root.lastAppliedTabBarRect, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 24))
        assertEquals(window1.frames.last, Rect(topLeftX: 0, topLeftY: 24, width: 1920, height: 1055))
        assertEquals(window2.frames.last, Rect(topLeftX: 0, topLeftY: 24, width: 1920, height: 1055))
        // The container keeps its whole slot, the bar included
        assertEquals(root.lastAppliedLayoutPhysicalRect, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1079))
    }

    @Test func testSingleChildStillHasTheBar() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        workspace.rootTilingContainer.layout = .accordion
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(workspace.rootTilingContainer.lastAppliedTabBarRect, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 24))
        assertEquals(window.frames.last, Rect(topLeftX: 0, topLeftY: 24, width: 1920, height: 1055))
    }

    @Test func testVerticalAccordion() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        root.changeOrientation(.v)
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        assertEquals(root.lastAppliedTabBarRect, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 24))
        assertEquals(window1.frames.last, Rect(topLeftX: 0, topLeftY: 24, width: 1920, height: 1055))
        assertEquals(window2.frames.last, Rect(topLeftX: 0, topLeftY: 24, width: 1920, height: 1055))
    }

    @Test func testAccordionPaddingIsForcedToZero() async throws {
        config.accordionPadding = 30
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        let windows = (1 ... 3).map { TestWindow.new(id: OpaqueWindowId(UInt64($0)), parent: root) }
        _ = windows[1].focusWindow()
        try await workspace.layoutWorkspace()
        for window in windows {
            assertEquals(window.frames.last, Rect(topLeftX: 0, topLeftY: 24, width: 1920, height: 1055))
        }

        // Without the bar, the padding is back
        config.tabBar.enabled = false
        try await workspace.layoutWorkspace()
        assertEquals(windows[0].frames.last, Rect(topLeftX: 0, topLeftY: 0, width: 1890, height: 1079))
        assertEquals(root.lastAppliedTabBarRect, nil)
    }

    @Test func testNestedAccordionsHaveTheirOwnBars() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        TestWindow.new(id: 1, parent: root)
        let inner = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST)
        let window2 = TestWindow.new(id: 2, parent: inner)
        try await workspace.layoutWorkspace()
        assertEquals(root.lastAppliedTabBarRect, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 24))
        assertEquals(inner.lastAppliedTabBarRect, Rect(topLeftX: 0, topLeftY: 24, width: 1920, height: 24))
        assertEquals(window2.frames.last, Rect(topLeftX: 0, topLeftY: 48, width: 1920, height: 1031))
    }

    @Test func testAccordionInTilesWithGaps() async throws {
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 20, bottom: 20, top: 20, right: 20))
        config.tabBar.gap = 4
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let accordion = TilingContainer(parent: root, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST)
        let window2 = TestWindow.new(id: 2, parent: accordion)
        try await workspace.layoutWorkspace()
        // The tiles around the accordion don't have a bar
        assertEquals(root.lastAppliedTabBarRect, nil)
        assertEquals(window1.frames.last, Rect(topLeftX: 20, topLeftY: 20, width: 935, height: 1039))
        assertEquals(accordion.lastAppliedTabBarRect, Rect(topLeftX: 965, topLeftY: 20, width: 935, height: 24))
        assertEquals(window2.frames.last, Rect(topLeftX: 965, topLeftY: 48, width: 935, height: 1011))
    }

    @Test func testBarIsForgottenWhenTheLayoutChanges() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        let window = TestWindow.new(id: 1, parent: root)
        try await workspace.layoutWorkspace()
        assertEquals(root.lastAppliedTabBarRect?.height, 24)

        root.layout = .tiles
        try await workspace.layoutWorkspace()
        assertEquals(root.lastAppliedTabBarRect, nil)
        assertEquals(window.frames.last, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1079))
    }

    @Test func testTilingOnlyLayoutUpdatesTheBar() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        TestWindow.new(id: 1, parent: root)
        config.tabBar.height = 40
        try await workspace.layoutTilingWindows()
        assertEquals(root.lastAppliedTabBarRect, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 40))
    }

    @Test func testCocoaFrame() {
        let rect = Rect(topLeftX: 10, topLeftY: 20, width: 300, height: 24)
        assertEquals(rect.cocoaFrame, CGRect(x: 10, y: 1080 - 20 - 24, width: 300, height: 24))
        assertEquals(rect.cocoaFrame.withYAxisFlipped, rect)
    }
}
