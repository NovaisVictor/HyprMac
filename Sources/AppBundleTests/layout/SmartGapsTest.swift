@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct SmartGapsTest {
    init() {
        setUpWorkspacesForTests()
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 20, bottom: 20, top: 20, right: 20))
    }

    @Test func testSingleWindowHasNoGaps() async throws {
        config.gaps.smart = .constant(true)
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(window.frames.last, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1079))
    }

    @Test func testSmartGapsApplyOnTopOfWorkspaceRuleGaps() async throws {
        config.gaps.smart = .constant(true)
        config.workspaceRules = [name: WorkspaceRule(gaps: GapsOverride(outer: .init(left: .constant(100))))]
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(window1.frames.last, Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1079))
        // Floating windows keep the gaps of the workspace rule: smart gaps only concern the tiling layout
        assertEquals(workspace.visibleRectPaddedByOuterGaps.topLeftX, 100)

        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(window1.frames.last?.topLeftX, 100)
    }

    @Test func testTwoWindowsKeepTheGaps() async throws {
        config.gaps.smart = .constant(true)
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(window1.frames.last, Rect(topLeftX: 20, topLeftY: 20, width: 935, height: 1039))
        assertEquals(window2.frames.last, Rect(topLeftX: 965, topLeftY: 20, width: 935, height: 1039))
    }

    @Test func testAccordionWithSeveralWindowsKeepsTheGaps() async throws {
        config.gaps.smart = .constant(true)
        config.accordionPadding = 0
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        workspace.rootTilingContainer.layout = .accordion
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(window1.frames.last, Rect(topLeftX: 20, topLeftY: 20, width: 1880, height: 1039))
    }

    @Test func testSmartGapsAreOffByDefault() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(window.frames.last, Rect(topLeftX: 20, topLeftY: 20, width: 1880, height: 1039))
    }

    @Test func testPerMonitorValue() async throws {
        config.gaps.smart = .perMonitor([PerMonitorValue(description: .main, value: false)], default: true)
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(window.frames.last, Rect(topLeftX: 20, topLeftY: 20, width: 1880, height: 1039))
    }

    @Test func testFloatingReferenceKeepsTheRealGaps() {
        config.gaps.smart = .constant(true)
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps, Rect(topLeftX: 20, topLeftY: 20, width: 1880, height: 1040))
    }
}
