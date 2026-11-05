@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct SplitControlsCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testToggleSplitFlipsOnlyTheParent() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                TestWindow.new(id: 3, parent: $0)
            }
        }

        assertEquals(await parseCommand("toggle-split").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 0)
        assertEquals(root.layoutDescription, .h_tiles([
            .window(1),
            .h_tiles([.window(2), .window(3)]),
        ]))
        assertTrue((root.children[1] as! TilingContainer).hasPinnedOrientation)
    }

    @Test func testToggleSplitSurvivesOppositeOrientationNormalization() async {
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                TestWindow.new(id: 3, parent: $0)
            }
        }

        await parseCommand("toggle-split").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([
            .window(1),
            .h_tiles([.window(2), .window(3)]),
        ]))
    }

    @Test func testToggleSplitWithWindowId() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }

        await parseCommand("toggle-split --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([
            .window(1),
            .h_tiles([.window(2), .window(3)]),
        ]))
    }

    @Test func testToggleSplitFailsInAccordion() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            $0.layout = .accordion
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        let result = await parseCommand("toggle-split").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["The parent container of the window has 'accordion' layout. Only 'tiles' containers can be split"])
        assertEquals(root.orientation, .h)
    }

    @Test func testToggleSplitFailsForFloatingWindow() async {
        let workspace = Workspace.get(byName: name)
        assertEquals(TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer).focusWindow(), true)

        let result = await parseCommand("toggle-split").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["The window has no tiling parent container. Floating, minimized and macOS fullscreen windows can't be split"])
    }

    @Test func testSwapSplitReversesChildrenAndKeepsWeights() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
        let window2 = TestWindow.new(id: 2, parent: root, adaptiveWeight: 2)
        let window3 = TestWindow.new(id: 3, parent: root, adaptiveWeight: 3)
        assertEquals(window2.focusWindow(), true)

        assertEquals(await parseCommand("swap-split").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 0)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))
        assertEquals(window1.hWeight, 1)
        assertEquals(window2.hWeight, 2)
        assertEquals(window3.hWeight, 3)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 2)
    }

    @Test func testSwapSplitActsOnNestedParent() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                TestWindow.new(id: 3, parent: $0)
            }
        }

        await parseCommand("swap-split").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(3), .window(2)]),
        ]))
    }
}
