@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FrozenTilingTreeTest {
    init() { setUpWorkspacesForTests() }

    @Test func testRestoreRoundTrip() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root, adaptiveWeight: 300)
        var window3: TestWindow!
        var window5: TestWindow!
        let dwindle = TilingContainer.newVTiles(parent: root, adaptiveWeight: 700, index: INDEX_BIND_LAST).apply {
            $0.hasPinnedOrientation = true
            let window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 200)
            window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 800)
            window2.markAsMostRecentChild()
        }
        let master = TilingContainer(parent: root, adaptiveWeight: 500, .v, .master, index: INDEX_BIND_LAST).apply {
            $0.masterRatio = 0.7
            $0.masterPlacement = .center
            TestWindow.new(id: 4, parent: $0)
            window5 = TestWindow.new(id: 5, parent: $0)
        }
        window1.markAsMostRecentChild()
        let frozen = FrozenTilingTree(workspace)
        assertEquals(frozen.root.mruChildIndices, [0, 2, 1])
        assertEquals(frozen.root.children.getOrNil(atIndex: 1).flatMap(\.asContainer)?.mruChildIndices, [0, 1])
        let layoutBefore = root.layoutDescription

        swapWindows(mruDominant: window1, window5)
        window3.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: 0)
        dwindle.hasPinnedOrientation = false
        master.masterRatio = 0.4
        master.masterPlacement = nil
        root.children.first.orDie().setWeight(.h, 42)

        restoreTilingTrees([frozen])
        let restoredRoot = workspace.rootTilingContainer
        assertEquals(restoredRoot.layoutDescription, layoutBefore)
        assertEquals(FrozenContainer(restoredRoot), frozen.root)
        assertEquals(restoredRoot.mostRecentWindowRecursive?.windowId, 1)
        assertTrue(window1.parent === restoredRoot)
        assertEquals(window1.hWeight, 300)
    }

    @Test func testRestoreBringsBackWindowMovedToAnotherWorkspace() {
        let source = Workspace.get(byName: name)
        let target = Workspace.get(byName: "target")
        let window1 = TestWindow.new(id: 1, parent: source.rootTilingContainer)
        TestWindow.new(id: 2, parent: source.rootTilingContainer)
        TestWindow.new(id: 3, parent: target.rootTilingContainer)
        let frozen = [FrozenTilingTree(source), FrozenTilingTree(target)]

        window1.bind(to: target.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
        restoreTilingTrees(frozen)
        assertEquals(source.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(target.rootTilingContainer.layoutDescription, .h_tiles([.window(3)]))
    }

    @Test func testClosedWindowsCacheRestoresMasterStatePinnedOrientationAndMru() async throws {
        resetClosedWindowsCache()
        defer { resetClosedWindowsCache() }
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        var window1: TestWindow!
        let master = TilingContainer(parent: root, adaptiveWeight: 600, .v, .master, index: INDEX_BIND_LAST).apply {
            $0.masterRatio = 0.7
            $0.masterPlacement = .center
            $0.hasPinnedOrientation = true
            window1 = TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0).markAsMostRecentChild()
        }
        let window3 = TestWindow.new(id: 3, parent: root, adaptiveWeight: 400)
        window3.markAsMostRecentChild()
        let frozen = FrozenContainer(root)
        assertEquals(frozen.mruChildIndices, [1, 0])
        cacheClosedWindowIfNeeded()

        master.masterRatio = 0.3
        master.masterPlacement = nil
        master.hasPinnedOrientation = false
        window1.markAsMostRecentChild()
        // The windows must be alive somewhere to be restored
        let other = Workspace.get(byName: "other")
        for window in root.allLeafWindowsRecursive {
            window.bind(to: other.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }

        assertTrue(try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window1))
        assertEquals(FrozenContainer(workspace.rootTilingContainer), frozen)
        assertEquals(workspace.rootTilingContainer.mostRecentWindowRecursive?.windowId, 3)
    }

    @Test func testRestoreSkipsClosedWindowsAndKeepsNewOnes() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        TestWindow.new(id: 3, parent: root)
        let frozen = FrozenTilingTree(workspace)

        window2.unbindFromParent()
        TestWindow.new(id: 4, parent: root)
        restoreTilingTrees([frozen])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3), .window(4)]))
    }
}

extension FrozenTreeNode {
    fileprivate var asContainer: FrozenContainer? {
        switch self {
            case .container(let container): container
            case .window: nil
        }
    }
}
