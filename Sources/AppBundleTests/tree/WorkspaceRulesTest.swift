@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct WorkspaceRulesTest {
    init() { setUpWorkspacesForTests() }

    @Test func testRootContainerOfNewWorkspace() {
        config.workspaceRules = ["G": WorkspaceRule(defaultRootContainerLayout: .accordion, defaultRootContainerOrientation: .vertical)]
        let root = Workspace.get(byName: "G").rootTilingContainer
        assertEquals(root.layout, .accordion)
        assertEquals(root.orientation, .v)

        let other = Workspace.get(byName: name).rootTilingContainer
        assertEquals(other.layout, .tiles)
        assertEquals(other.orientation, .h)
    }

    @Test func testRuleIsReappliedWhenEmptyWorkspaceIsGarbageCollected() {
        config.workspaceRules = ["G": WorkspaceRule(defaultRootContainerLayout: .accordion)]
        let workspace = Workspace.get(byName: "G")
        workspace.rootTilingContainer.layout = .tiles // E.g. 'layout --workspace G --root tiles'
        Workspace.garbageCollectUnusedWorkspaces()
        assertEquals(Workspace.get(byName: "G").rootTilingContainer.layout, .accordion)
    }

    @Test func testConfigReloadRecreatesOnlyEmptyRootsOfRuleWorkspaces() {
        let empty = Workspace.get(byName: "empty").rootTilingContainer
        let nonEmpty = Workspace.get(byName: "nonEmpty").rootTilingContainer
        TestWindow.new(id: 1, parent: nonEmpty)
        let withoutRule = Workspace.get(byName: "withoutRule").rootTilingContainer

        let previousConfig = config
        config.defaultRootContainerLayout = .master
        let rule = WorkspaceRule(defaultRootContainerLayout: .accordion)
        config.workspaceRules = ["empty": rule, "nonEmpty": rule]
        Workspace.recreateEmptyRootContainers(affectedByRulesOf: previousConfig)

        assertTrue(empty.parent == nil)
        assertEquals(Workspace.get(byName: "empty").rootTilingContainer.layout, .accordion)
        assertTrue(Workspace.get(byName: "nonEmpty").rootTilingContainer === nonEmpty)
        assertEquals(nonEmpty.layout, .tiles)
        // The global defaults keep the upstream behavior
        assertTrue(Workspace.get(byName: "withoutRule").rootTilingContainer === withoutRule)
        assertEquals(withoutRule.layout, .tiles)
    }

    @Test func testConfigReloadResetsEmptyRootWhenRuleIsRemoved() {
        config.workspaceRules = ["G": WorkspaceRule(defaultRootContainerLayout: .accordion)]
        assertEquals(Workspace.get(byName: "G").rootTilingContainer.layout, .accordion)

        let previousConfig = config
        config.workspaceRules = [:]
        Workspace.recreateEmptyRootContainers(affectedByRulesOf: previousConfig)
        assertEquals(Workspace.get(byName: "G").rootTilingContainer.layout, .tiles)
    }

    @Test func testOuterGapsPerWorkspace() async throws {
        config.gaps.outer = .init(left: .constant(10), bottom: .constant(20), top: .constant(30), right: .constant(40))
        config.workspaceRules = ["G": WorkspaceRule(gaps: GapsOverride(outer: .init(left: .constant(100))))]
        let monitorRect = mainMonitorInfo.visibleRect

        let g = Workspace.get(byName: "G")
        assertEquals(g.visibleRectPaddedByOuterGaps, Rect(
            topLeftX: monitorRect.topLeftX + 100,
            topLeftY: monitorRect.topLeftY + 30,
            width: monitorRect.width - 140,
            height: monitorRect.height - 50,
        ))
        let other = Workspace.get(byName: name)
        assertEquals(other.visibleRectPaddedByOuterGaps, mainMonitorInfo.visibleRectPaddedByOuterGaps)
        assertEquals(other.visibleRectPaddedByOuterGaps.topLeftX, monitorRect.topLeftX + 10)

        let window = TestWindow.new(id: 1, parent: g.rootTilingContainer)
        try await g.layoutWorkspace()
        assertEquals(window.lastAppliedLayoutPhysicalRect?.topLeftX, monitorRect.topLeftX + 100)
        assertEquals(window.lastAppliedLayoutPhysicalRect?.width, monitorRect.width - 140)
    }

    @Test func testInnerGapsPerWorkspace() async throws {
        config.workspaceRules = ["G": WorkspaceRule(gaps: GapsOverride(inner: .init(horizontal: .constant(20))))]
        let g = Workspace.get(byName: "G")
        let window1 = TestWindow.new(id: 1, parent: g.rootTilingContainer)
        let window2 = TestWindow.new(id: 2, parent: g.rootTilingContainer)
        try await g.layoutWorkspace()
        let left = window1.lastAppliedLayoutPhysicalRect.orDie()
        let right = window2.lastAppliedLayoutPhysicalRect.orDie()
        assertEquals(right.topLeftX - (left.topLeftX + left.width), 20)
    }

    @Test func testSplitOnlyInWorkspaceWithFlattenDisabled() async {
        config.enableNormalizationFlattenContainers = true
        config.workspaceRules = ["G": WorkspaceRule(enableNormalizationFlattenContainers: false)]

        let g = Workspace.get(byName: "G")
        let root = g.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }
        assertEquals(await parseCommand("split vertical").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 0)
        g.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(1)]), .window(2)]))

        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 3, parent: $0).focusWindow(), true)
            TestWindow.new(id: 4, parent: $0)
        }
        let result = await parseCommand("split vertical").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
    }

    @Test func testFlattenNormalizationPerWorkspace() {
        config.enableNormalizationFlattenContainers = false
        config.workspaceRules = ["G": WorkspaceRule(enableNormalizationFlattenContainers: true)]
        func populate(_ workspace: Workspace, ids: (OpaqueWindowId, OpaqueWindowId)) -> TilingContainer {
            workspace.rootTilingContainer.apply {
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: ids.0, parent: $0)
                }
                TestWindow.new(id: ids.1, parent: $0)
            }
        }
        let g = Workspace.get(byName: "G")
        let gRoot = populate(g, ids: (1, 2))
        g.normalizeContainers()
        assertEquals(gRoot.layoutDescription, .h_tiles([.window(1), .window(2)]))

        let other = Workspace.get(byName: name)
        let otherRoot = populate(other, ids: (3, 4))
        other.normalizeContainers()
        assertEquals(otherRoot.layoutDescription, .h_tiles([.v_tiles([.window(3)]), .window(4)]))
    }

    @Test func testOppositeOrientationNormalizationPerWorkspace() {
        config.workspaceRules = ["G": WorkspaceRule(enableNormalizationOppositeOrientationForNestedContainers: true)]
        func populate(_ workspace: Workspace, ids: [OpaqueWindowId]) -> TilingContainer {
            workspace.rootTilingContainer.apply {
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: ids[0], parent: $0)
                    TestWindow.new(id: ids[1], parent: $0)
                }
                TestWindow.new(id: ids[2], parent: $0)
            }
        }
        let g = Workspace.get(byName: "G")
        let gRoot = populate(g, ids: [1, 2, 3])
        g.normalizeContainers()
        assertEquals(gRoot.layoutDescription, .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)]))

        let other = Workspace.get(byName: name)
        let otherRoot = populate(other, ids: [4, 5, 6])
        other.normalizeContainers()
        assertEquals(otherRoot.layoutDescription, .h_tiles([.h_tiles([.window(4), .window(5)]), .window(6)]))
    }

    @Test func testChangeOrientationFollowsWorkspaceNormalization() {
        config.workspaceRules = ["G": WorkspaceRule(enableNormalizationOppositeOrientationForNestedContainers: true)]
        var nested: TilingContainer! = nil
        let root = Workspace.get(byName: "G").rootTilingContainer.apply {
            nested = TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
            }
        }
        nested.changeOrientation(.h)
        // With the normalization, the whole chain of parents is flipped
        assertEquals(root.orientation, .v)
        assertEquals(nested.orientation, .h)
    }

    @Test func testNewWindowPlacementPerWorkspace() {
        config.workspaceRules = ["G": WorkspaceRule(newWindowPlacement: .dwindle)]
        func populateAndPlace(_ workspace: Workspace, ids: [OpaqueWindowId]) -> TilingContainer {
            let root = workspace.rootTilingContainer
            TestWindow.new(id: ids[0], parent: root)
            TestWindow.new(id: ids[1], parent: root).apply {
                $0.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 1000)
                $0.markAsMostRecentChild()
            }
            let data = NewWindowParentKind.tiling.unbindAndGetBindingData(workspace, window: nil)
            TestWindow.new(id: ids[2], parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
            return root
        }
        assertEquals(populateAndPlace(Workspace.get(byName: "G"), ids: [1, 2, 3]).layoutDescription, .h_tiles([
            .window(1),
            .v_tiles([.window(2), .window(3)]),
        ]))
        assertEquals(populateAndPlace(Workspace.get(byName: name), ids: [4, 5, 6]).layoutDescription, .h_tiles([
            .window(4),
            .window(5),
            .window(6),
        ]))
    }
}
