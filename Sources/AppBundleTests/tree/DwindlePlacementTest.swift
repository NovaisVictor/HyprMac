@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct DwindlePlacementTest {
    init() { setUpWorkspacesForTests() }

    private func rect(width: CGFloat, height: CGFloat) -> Rect {
        Rect(topLeftX: 0, topLeftY: 0, width: width, height: height)
    }

    /// Mirrors what the new-window registration does: compute the binding and bind right away
    @discardableResult
    private func registerNewWindow(id: OpaqueWindowId, _ workspace: Workspace) -> TestWindow? {
        guard let data = workspace.unbindAndGetBindingDataForDwindleSplit() else { return nil }
        return TestWindow.new(id: id, parent: data.parent)
    }

    @Test func testWideWindowIsSplitHorizontally() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root).apply {
            $0.lastAppliedLayoutPhysicalRect = rect(width: 1000, height: 500)
            $0.markAsMostRecentChild()
        }

        assertNotNil(registerNewWindow(id: 3, workspace))
        assertEquals(root.layoutDescription, .h_tiles([
            .window(1),
            .h_tiles([.window(2), .window(3)]),
        ]))
    }

    @Test func testTallWindowIsSplitVertically() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root).apply {
            $0.lastAppliedLayoutPhysicalRect = rect(width: 500, height: 1000)
            $0.markAsMostRecentChild()
        }
        TestWindow.new(id: 2, parent: root)
        root.children.first.orDie().markAsMostRecentChild()

        assertNotNil(registerNewWindow(id: 3, workspace))
        assertEquals(root.layoutDescription, .h_tiles([
            .v_tiles([.window(1), .window(3)]),
            .window(2),
        ]))
    }

    @Test func testSplitContainerKeepsWeightOfSplitWindow() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
        TestWindow.new(id: 2, parent: root, adaptiveWeight: 3).markAsMostRecentChild()

        let window3 = registerNewWindow(id: 3, workspace).orDie()
        let splitContainer = window3.parent.orDie() as! TilingContainer
        assertEquals(splitContainer.getWeight(root.orientation), 3)
        assertTrue(splitContainer.hasPinnedOrientation)
    }

    @Test func testUnknownRectFallsBackToOppositeOrientation() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root).markAsMostRecentChild()

        assertNotNil(registerNewWindow(id: 3, workspace))
        assertEquals(root.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .window(3)]),
        ]))
    }

    @Test func testSingleWindowFallsBackToSibling() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer).markAsMostRecentChild()

        assertNil(workspace.unbindAndGetBindingDataForDwindleSplit())
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    @Test func testEmptyWorkspaceFallsBackToSibling() {
        assertNil(Workspace.get(byName: name).unbindAndGetBindingDataForDwindleSplit())
    }

    @Test func testAccordionIsNotSplit() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root).markAsMostRecentChild()

        assertNil(workspace.unbindAndGetBindingDataForDwindleSplit())
    }

    @Test func testOppositeOrientationNormalizationKeepsDwindleOrientation() {
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root).apply {
            $0.lastAppliedLayoutPhysicalRect = rect(width: 1000, height: 500)
            $0.markAsMostRecentChild()
        }
        assertNotNil(registerNewWindow(id: 3, workspace))
        // Control: a regular nested container with the same orientation as its parent gets flipped
        TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
            TestWindow.new(id: 4, parent: $0)
            TestWindow.new(id: 5, parent: $0)
        }

        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([
            .window(1),
            .h_tiles([.window(2), .window(3)]),
            .v_tiles([.window(4), .window(5)]),
        ]))
    }

    /// Mirrors what the new-window registration does with the configured new-window-placement
    @discardableResult
    private func placeNewWindow(id: OpaqueWindowId, _ workspace: Workspace) -> TestWindow {
        let data = NewWindowParentKind.tiling.unbindAndGetBindingData(workspace, window: nil)
        return TestWindow.new(id: id, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }

    @Test(arguments: CardinalDirection.allCases)
    func testPreselectInEachDirection(direction: CardinalDirection) {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root, adaptiveWeight: 3).apply {
            // The preselection wins over the aspect ratio
            $0.lastAppliedLayoutPhysicalRect = rect(width: 1000, height: 500)
            $0.preselect = direction
            $0.markAsMostRecentChild()
        }

        let window3 = placeNewWindow(id: 3, workspace)
        let expected: LayoutDescription = switch direction {
            case .left: .h_tiles([.window(3), .window(2)])
            case .right: .h_tiles([.window(2), .window(3)])
            case .up: .v_tiles([.window(3), .window(2)])
            case .down: .v_tiles([.window(2), .window(3)])
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), expected]))
        let splitContainer = window3.parent as! TilingContainer
        assertTrue(splitContainer.hasPinnedOrientation)
        assertEquals(splitContainer.getWeight(root.orientation), 3)
    }

    @Test func testPreselectWorksWithDwindlePlacement() {
        config.newWindowPlacement = .dwindle
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root).apply {
            $0.lastAppliedLayoutPhysicalRect = rect(width: 1000, height: 500)
            $0.preselect = .up
            $0.markAsMostRecentChild()
        }

        placeNewWindow(id: 3, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(3), .window(2)])]))
    }

    @Test func testPreselectSplitsSingleChildOfRoot() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root).apply {
            $0.preselect = .down
            $0.markAsMostRecentChild()
        }

        placeNewWindow(id: 2, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(1), .window(2)])]))
    }

    @Test func testPreselectAtRootIsFlattenedIntoRoot() {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer).apply {
            $0.preselect = .up
            $0.markAsMostRecentChild()
        }

        placeNewWindow(id: 2, workspace)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(2), .window(1)]))
    }

    @Test func testPreselectSplitsSingleChildOfNestedContainer() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0).apply {
                $0.preselect = .right
                $0.markAsMostRecentChild()
            }
        }

        placeNewWindow(id: 3, workspace)
        assertEquals(root.layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.h_tiles([.window(2), .window(3)])]),
        ]))
    }

    @Test func testPreselectIsUsedOnce() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root).apply {
            $0.preselect = .down
            $0.markAsMostRecentChild()
        }

        placeNewWindow(id: 3, workspace)
        assertNil(window2.preselect)
        window2.markAsMostRecentChild()
        // Sibling placement again
        placeNewWindow(id: 4, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(4), .window(3)])]))
    }

    @Test func testPreselectOfNotMostRecentWindowWaits() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root).apply { $0.preselect = .up }
        TestWindow.new(id: 2, parent: root).markAsMostRecentChild()

        placeNewWindow(id: 3, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(window1.preselect, .up)
    }

    @Test func testPreselectIsSkippedInAccordionAndKept() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.layout = .accordion
        TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root).apply {
            $0.preselect = .up
            $0.markAsMostRecentChild()
        }

        placeNewWindow(id: 3, workspace)
        assertEquals(root.layoutDescription, .h_accordion([.window(1), .window(2), .window(3)]))
        assertEquals(window2.preselect, .up)
    }

    @Test func testPreselectIsSkippedInMasterAndKept() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.layout = .master
        TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root).apply {
            $0.preselect = .up
            $0.markAsMostRecentChild()
        }

        placeNewWindow(id: 3, workspace)
        assertEquals(root.children.count, 3)
        assertEquals(window2.preselect, .up)
    }
}
