@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct TilingDropTest {
    init() { setUpWorkspacesForTests() }

    @Test func testSwapWithWindowUnderPoint() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root).apply { $0.lastAppliedLayoutPhysicalRect = rect(x: 0, width: 500) }
        TestWindow.new(id: 2, parent: root).apply { $0.lastAppliedLayoutPhysicalRect = rect(x: 500, width: 500) }

        let action = resolveTilingDrop(window1, at: CGPoint(x: 750, y: 500), targetWorkspace: workspace)
        guard case .swap(let target) = action else { Issue.record("Expected swap, got \(action)"); return }
        assertEquals(target.windowId, 2)

        action.apply(to: window1)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }

    @Test func testDropOnOwnSlotOrEmptySpaceIsNoop() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root).apply { $0.lastAppliedLayoutPhysicalRect = rect(x: 0, width: 500) }
        TestWindow.new(id: 2, parent: root).apply { $0.lastAppliedLayoutPhysicalRect = rect(x: 500, width: 500) }

        guard case .none = resolveTilingDrop(window1, at: CGPoint(x: 250, y: 500), targetWorkspace: workspace) else {
            Issue.record("Dropping on own slot must be noop")
            return
        }
        guard case .none = resolveTilingDrop(window1, at: CGPoint(x: 1500, y: 500), targetWorkspace: workspace) else {
            Issue.record("Dropping outside of windows must be noop")
            return
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    @Test func testAccordionDropSwapsWithMostRecentChild() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root).apply { $0.lastAppliedLayoutPhysicalRect = rect(x: 0, width: 500) }
        TilingContainer(parent: root, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST).apply {
            $0.lastAppliedLayoutPhysicalRect = rect(x: 500, width: 500)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0).markAsMostRecentChild()
        }

        let action = resolveTilingDrop(window1, at: CGPoint(x: 600, y: 500), targetWorkspace: workspace)
        guard case .swap(let target) = action else { Issue.record("Expected swap, got \(action)"); return }
        assertEquals(target.windowId, 3)
    }

    @Test func testSwapPreservesDwindleContainers() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root).apply { $0.lastAppliedLayoutPhysicalRect = rect(x: 0, width: 500) }
        let split = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).apply {
            $0.hasPinnedOrientation = true
            $0.lastAppliedLayoutPhysicalRect = rect(x: 500, width: 500)
            TestWindow.new(id: 2, parent: $0).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 500)
            TestWindow.new(id: 3, parent: $0).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 500, topLeftY: 500, width: 500, height: 500)
        }

        resolveTilingDrop(window1, at: CGPoint(x: 750, y: 750), targetWorkspace: workspace).apply(to: window1)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .v_tiles([.window(2), .window(1)])]))
        assertTrue(split.hasPinnedOrientation)
        assertTrue(split.parent === root)
    }

    @Test func testDropOnAnotherMonitorRebindsNextToTarget() {
        let sourceWorkspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: sourceWorkspace.rootTilingContainer)
            .apply { $0.lastAppliedLayoutPhysicalRect = rect(x: 0, width: 500) }
        let targetWorkspace = Workspace.get(byName: "target")
        let targetRoot = targetWorkspace.rootTilingContainer
        TestWindow.new(id: 2, parent: targetRoot).apply { $0.lastAppliedLayoutPhysicalRect = rect(x: 0, width: 500) }
        TestWindow.new(id: 3, parent: targetRoot).apply { $0.lastAppliedLayoutPhysicalRect = rect(x: 500, width: 500) }

        let action = resolveTilingDrop(window1, at: CGPoint(x: 400, y: 500), targetWorkspace: targetWorkspace)
        guard case .rebind(let parent, let index) = action else { Issue.record("Expected rebind, got \(action)"); return }
        assertTrue(parent === targetRoot)
        assertEquals(index, 1) // Right half of window 2

        action.apply(to: window1)
        assertEquals(targetRoot.layoutDescription, .h_tiles([.window(2), .window(1), .window(3)]))
    }

    @Test func testDropOnEmptyMonitorRebindsToRoot() {
        let sourceWorkspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: sourceWorkspace.rootTilingContainer)
        let targetWorkspace = Workspace.get(byName: "target")

        let action = resolveTilingDrop(window1, at: CGPoint(x: 400, y: 500), targetWorkspace: targetWorkspace)
        guard case .rebind(let parent, let index) = action else { Issue.record("Expected rebind, got \(action)"); return }
        assertTrue(parent === targetWorkspace.rootTilingContainer)
        assertEquals(index, 0)
    }
}

private func rect(x: CGFloat, width: CGFloat) -> Rect {
    Rect(topLeftX: x, topLeftY: 0, width: width, height: 1000)
}
