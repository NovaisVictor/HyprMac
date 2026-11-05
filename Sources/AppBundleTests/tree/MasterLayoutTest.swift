@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct MasterLayoutTest {
    init() { setUpWorkspacesForTests() }

    private let noGaps = ResolvedGaps.Inner(vertical: 0, horizontal: 0)

    private func frames(
        width: CGFloat = 1000,
        height: CGFloat = 600,
        _ orientation: Orientation,
        ratio: CGFloat,
        _ placement: MasterPlacement = .start,
        count: Int,
        gaps: ResolvedGaps.Inner? = nil,
    ) -> (virtual: [[CGFloat]], physical: [[CGFloat]]) {
        let result = masterLayoutFrames(
            width: width,
            height: height,
            orientation: orientation,
            ratio: ratio,
            placement: placement,
            count: count,
            innerGaps: gaps ?? noGaps,
        )
        return (result.map { $0.virtual.components }, result.map { $0.physical.components })
    }

    /// root: h_master [1 (master), 2, 3, 4]
    @discardableResult
    private func setUpHMaster(focused: OpaqueWindowId? = nil) -> TilingContainer {
        let root = Workspace.get(byName: name).rootTilingContainer
        root.layout = .master
        for id: OpaqueWindowId in [1, 2, 3, 4] {
            TestWindow.new(id: id, parent: root)
        }
        if let focused {
            assertEquals(Window.get(byId: focused)?.focusWindow(), true)
        }
        return root
    }

    private func run(_ command: String) async {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    // ===================================================== Geometry

    @Test func testGeometryNoChildren() {
        assertEquals(frames(.h, ratio: 0.5, count: 0).virtual, [])
    }

    @Test func testGeometrySingleChildTakesEverything() {
        let gaps = ResolvedGaps.Inner(vertical: 20, horizontal: 10)
        let result = frames(.h, ratio: 0.6, count: 1, gaps: gaps)
        assertEquals(result.virtual, [[0, 0, 1000, 600]])
        assertEquals(result.physical, [[0, 0, 1000, 600]])
    }

    @Test func testGeometryHorizontalTwoChildren() {
        assertEquals(frames(.h, ratio: 0.5, count: 2).virtual, [
            [0, 0, 500, 600],
            [500, 0, 500, 600],
        ])
    }

    @Test func testGeometryHorizontalManyChildren() {
        assertEquals(frames(.h, ratio: 0.6, count: 4).virtual, [
            [0, 0, 600, 600],
            [600, 0, 400, 200],
            [600, 200, 400, 200],
            [600, 400, 400, 200],
        ])
    }

    @Test func testGeometryVerticalManyChildren() {
        assertEquals(frames(width: 1000, height: 800, .v, ratio: 0.5, count: 3).virtual, [
            [0, 0, 1000, 400],
            [0, 400, 500, 400],
            [500, 400, 500, 400],
        ])
    }

    @Test func testGeometryRatioIsClamped() {
        assertEquals(frames(.h, ratio: 2, count: 2).virtual, [
            [0, 0, 900, 600],
            [900, 0, 100, 600],
        ])
        assertEquals(frames(.h, ratio: 0, count: 2).virtual, [
            [0, 0, 100, 600],
            [100, 0, 900, 600],
        ])
    }

    @Test func testGeometryGapsAreOnlyBetweenChildren() {
        let gaps = ResolvedGaps.Inner(vertical: 20, horizontal: 10)
        let result = frames(.h, ratio: 0.5, count: 3, gaps: gaps)
        assertEquals(result.virtual, [
            [0, 0, 500, 600],
            [500, 0, 500, 300],
            [500, 300, 500, 300],
        ])
        assertEquals(result.physical, [
            [0, 0, 495, 600],
            [505, 0, 495, 290],
            [505, 310, 495, 290],
        ])
    }

    @Test func testGeometryGapsVertical() {
        let gaps = ResolvedGaps.Inner(vertical: 20, horizontal: 10)
        let result = frames(width: 900, height: 800, .v, ratio: 0.5, count: 4, gaps: gaps)
        assertEquals(result.physical, [
            [0, 0, 900, 390],
            [0, 410, 295, 390],
            [305, 410, 290, 390],
            [605, 410, 295, 390],
        ])
    }

    // ===================================================== Center geometry

    @Test func testGeometryCenterFallsBackToStartBelowThreeChildren() {
        assertEquals(frames(.h, ratio: 0.5, .center, count: 1).virtual, [[0, 0, 1000, 600]])
        assertEquals(frames(.h, ratio: 0.5, .center, count: 2).virtual, [
            [0, 0, 500, 600],
            [500, 0, 500, 600],
        ])
    }

    @Test func testGeometryCenterThreeChildren() {
        // The first stack child goes to the right, the second one to the left
        assertEquals(frames(.h, ratio: 0.5, .center, count: 3).virtual, [
            [250, 0, 500, 600],
            [750, 0, 250, 600],
            [0, 0, 250, 600],
        ])
        assertEquals(frames(.h, ratio: 0.6, .center, count: 3).virtual, [
            [200, 0, 600, 600],
            [800, 0, 200, 600],
            [0, 0, 200, 600],
        ])
    }

    @Test func testGeometryCenterFourChildren() {
        assertEquals(frames(.h, ratio: 0.5, .center, count: 4).virtual, [
            [250, 0, 500, 600],
            [750, 0, 250, 300],
            [0, 0, 250, 600],
            [750, 300, 250, 300],
        ])
    }

    @Test func testGeometryCenterFiveChildren() {
        assertEquals(frames(.h, ratio: 0.5, .center, count: 5).virtual, [
            [250, 0, 500, 600],
            [750, 0, 250, 300],
            [0, 0, 250, 300],
            [750, 300, 250, 300],
            [0, 300, 250, 300],
        ])
    }

    @Test func testGeometryCenterVertical() {
        assertEquals(frames(width: 1000, height: 800, .v, ratio: 0.5, .center, count: 4).virtual, [
            [0, 200, 1000, 400],
            [0, 600, 500, 200],
            [0, 0, 1000, 200],
            [500, 600, 500, 200],
        ])
    }

    @Test func testGeometryCenterRatioIsClamped() {
        assertEquals(frames(.h, ratio: 2, .center, count: 3).virtual, [
            [50, 0, 900, 600],
            [950, 0, 50, 600],
            [0, 0, 50, 600],
        ])
    }

    @Test func testGeometryCenterGaps() {
        let gaps = ResolvedGaps.Inner(vertical: 20, horizontal: 10)
        let result = frames(.h, ratio: 0.5, .center, count: 4, gaps: gaps)
        assertEquals(result.virtual, [
            [250, 0, 500, 600],
            [750, 0, 250, 300],
            [0, 0, 250, 600],
            [750, 300, 250, 300],
        ])
        assertEquals(result.physical, [
            [255, 0, 490, 600],
            [755, 0, 245, 290],
            [0, 0, 245, 600],
            [755, 310, 245, 290],
        ])
    }

    @Test func testGeometryCenterGapsVertical() {
        let gaps = ResolvedGaps.Inner(vertical: 20, horizontal: 10)
        let result = frames(width: 900, height: 800, .v, ratio: 0.5, .center, count: 3, gaps: gaps)
        assertEquals(result.physical, [
            [0, 210, 900, 380],
            [0, 610, 900, 190],
            [0, 0, 900, 190],
        ])
    }

    // ===================================================== Layout command

    @Test func testParseLayoutCommand() {
        testParseSingleCommandSucc("layout master", LayoutCmdArgs(rawArgs: [], toggleBetween: [.master]))
        testParseSingleCommandSucc("layout h_master v_master", LayoutCmdArgs(rawArgs: [], toggleBetween: [.h_master, .v_master]))
        testParseSingleCommandSucc("layout --root master tiles", LayoutCmdArgs(rawArgs: [], toggleBetween: [.master, .tiles]).with(\.root, true))
        assertEquals("master".parseLayout(), .master)
    }

    @Test func testLayoutCommandSetsMaster() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        assertEquals(TestWindow.new(id: 1, parent: root).focusWindow(), true)
        TestWindow.new(id: 2, parent: root)

        await run("layout v_master")
        assertEquals(root.layoutDescription, .v_master([.window(1), .window(2)]))

        await run("layout master tiles")
        assertEquals(root.layoutDescription, .v_tiles([.window(1), .window(2)]))

        await run("layout master tiles")
        assertEquals(root.layoutDescription, .v_master([.window(1), .window(2)]))

        await run("layout horizontal")
        assertEquals(root.layoutDescription, .h_master([.window(1), .window(2)]))
    }

    @Test func testLayoutFormatVar() async {
        let root = setUpHMaster(focused: 2)
        let result = await parseCommand("list-windows --focused --format '%{window-parent-container-layout}'").cmdOrDie
            .run(.defaultEnv, .emptyStdin)
        assertEquals(result.stdout, ["h_master"])
        root.changeOrientation(.v)
        let result2 = await parseCommand("list-windows --focused --format '%{window-parent-container-layout}'").cmdOrDie
            .run(.defaultEnv, .emptyStdin)
        assertEquals(result2.stdout, ["v_master"])
    }

    @Test func testDefaultRootContainerLayoutConfig() {
        let result = parseConfig(
            """
            default-root-container-layout = 'master'
            master-ratio-percent = 60
            """,
        )
        assertEquals(result.strErrors, [])
        assertEquals(result.config.defaultRootContainerLayout, .master)
        assertEquals(result.config.masterRatioPercent, 60)
    }

    @Test func testMasterRatioPercentIsValidated() {
        assertEquals(
            parseConfig("master-ratio-percent = 95").strErrors,
            ["[ERROR] master-ratio-percent: master-ratio-percent must be in [10, 90] range"],
        )
    }

    // ===================================================== Navigation

    @Test func testFocusBetweenMasterAndStack() async {
        setUpHMaster(focused: 3)

        await run("focus left")
        assertEquals(globalFocus.windowOrNil?.windowId, 1)

        // Back to the stack window we came from
        await run("focus right")
        assertEquals(globalFocus.windowOrNil?.windowId, 3)

        // Nothing to the right of the stack
        await run("focus right")
        assertEquals(globalFocus.windowOrNil?.windowId, 3)
    }

    @Test func testFocusWithinStack() async {
        setUpHMaster(focused: 2)

        await run("focus down")
        assertEquals(globalFocus.windowOrNil?.windowId, 3)
        await run("focus down")
        assertEquals(globalFocus.windowOrNil?.windowId, 4)
        await run("focus down")
        assertEquals(globalFocus.windowOrNil?.windowId, 4)

        await run("focus up")
        await run("focus up")
        assertEquals(globalFocus.windowOrNil?.windowId, 2)
        // The master isn't above the stack
        await run("focus up")
        assertEquals(globalFocus.windowOrNil?.windowId, 2)
    }

    @Test func testFocusFromMasterAcrossOrientation() async {
        setUpHMaster(focused: 1)
        await run("focus down")
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
    }

    @Test func testFocusVerticalMaster() async {
        let root = setUpHMaster(focused: 1)
        root.changeOrientation(.v)

        await run("focus left")
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        // The most recent stack window
        await run("focus down")
        assertEquals(globalFocus.windowOrNil?.windowId, 4)
        await run("focus left")
        assertEquals(globalFocus.windowOrNil?.windowId, 3)
        await run("focus up")
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
    }

    @Test func testFocusIntoMasterContainerFromOutside() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let master = TilingContainer(parent: root, adaptiveWeight: 1, .h, .master, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: master)
        TestWindow.new(id: 2, parent: master)
        TestWindow.new(id: 3, parent: master)
        let outside = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        TestWindow.new(id: 4, parent: outside)

        assertEquals(Window.get(byId: 2)?.focusWindow(), true)
        assertEquals(Window.get(byId: 4)?.focusWindow(), true)
        // The stack side of the master container is entered through its most recent window
        await run("focus left")
        assertEquals(globalFocus.windowOrNil?.windowId, 2)
    }

    @Test func testMovePromotesStackWindowToMaster() async {
        let root = setUpHMaster(focused: 3)

        await run("move left")
        assertEquals(root.layoutDescription, .h_master([.window(3), .window(2), .window(1), .window(4)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 3)

        // Moving the master back exchanges it with the stack window it came from
        await run("move right")
        assertEquals(root.layoutDescription, .h_master([.window(1), .window(2), .window(3), .window(4)]))
    }

    @Test func testMoveWithinStack() async {
        let root = setUpHMaster(focused: 3)

        await run("move down")
        assertEquals(root.layoutDescription, .h_master([.window(1), .window(2), .window(4), .window(3)]))
        await run("move up")
        await run("move up")
        assertEquals(root.layoutDescription, .h_master([.window(1), .window(3), .window(2), .window(4)]))
    }

    @Test func testSwapWithMaster() async {
        let root = setUpHMaster(focused: 4)

        await run("swap left")
        assertEquals(root.layoutDescription, .h_master([.window(4), .window(2), .window(3), .window(1)]))
    }

    // ===================================================== Resize and balance-sizes

    @Test func testResizeAdjustsMasterRatio() async {
        let root = setUpHMaster(focused: 1)
        root.lastAppliedLayoutVirtualRect = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        assertEquals(root.effectiveMasterRatio, 0.55)
        root.masterRatio = 0.5

        await run("resize width +100")
        assertEquals(root.masterRatio, 0.6)

        assertEquals(Window.get(byId: 3)?.focusWindow(), true)
        await run("resize smart +50")
        assertEquals(root.masterRatio, 0.55)

        await run("resize width 300")
        assertEquals(root.masterRatio, 0.7)

        await run("resize width -1000")
        assertEquals(root.masterRatio, masterRatioRange.upperBound)

        // Stack children are evenly split, nothing to resize along the stack
        let result = await parseCommand("resize height +10").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)

        await run("balance-sizes")
        assertNil(root.masterRatio)
    }

    @Test func testResizeMasterBeforeLayoutFails() async {
        let root = setUpHMaster(focused: 1)
        let result = await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertNil(root.masterRatio)
    }

    // ===================================================== Tree interplay

    @Test func testNormalizationKeepsMasterContainer() {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        let root = setUpHMaster()
        root.masterRatio = 0.7
        let nested = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1)
        TestWindow.new(id: 5, parent: nested)
        TestWindow.new(id: 6, parent: nested)

        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_master([
            .window(1), .window(2), .window(3), .window(4),
            .v_tiles([.window(5), .window(6)]),
        ]))
        assertEquals(root.masterRatio, 0.7)
    }

    @Test func testRootFlatteningKeepsMasterContainer() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let master = TilingContainer(parent: root, adaptiveWeight: 1, .v, .master, index: INDEX_BIND_LAST)
        master.masterRatio = 0.3
        TestWindow.new(id: 1, parent: master)
        TestWindow.new(id: 2, parent: master)

        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_master([.window(1), .window(2)]))
        assertEquals(workspace.rootTilingContainer.masterRatio, 0.3)
    }

    // ===================================================== Center master

    /// root: h_center_master [1 (master), 2 (right), 3 (left), 4 (right), 5 (left)]
    @discardableResult
    private func setUpCenterMaster(focused: OpaqueWindowId, count: Int = 5) -> TilingContainer {
        let root = Workspace.get(byName: name).rootTilingContainer
        root.layout = .master
        root.masterPlacement = .center
        for id: OpaqueWindowId in [1, 2, 3, 4, 5].prefix(count) {
            TestWindow.new(id: id, parent: root)
        }
        assertEquals(Window.get(byId: focused)?.focusWindow(), true)
        return root
    }

    private func assertFocus(after command: String, _ expected: OpaqueWindowId, sourceLocation: SourceLocation = #_sourceLocation) async {
        await run(command)
        assertEquals(globalFocus.windowOrNil?.windowId, expected, additionalMsg: command, sourceLocation: sourceLocation)
    }

    @Test func testCenterStackSides() {
        let root = setUpCenterMaster(focused: 1)
        assertTrue(root.isMasterCentered)
        assertEquals(root.inhabitedStackChildren(on: .positive).map { ($0 as? Window)?.windowId }, [2, 4])
        assertEquals(root.inhabitedStackChildren(on: .negative).map { ($0 as? Window)?.windowId }, [3, 5])
    }

    @Test func testCenterFocusBetweenMasterAndStacks() async {
        setUpCenterMaster(focused: 1)
        // The most recent window of each stack
        await assertFocus(after: "focus right", 4)
        await assertFocus(after: "focus left", 1)
        await assertFocus(after: "focus left", 5)
        // Nothing to the left of the left stack
        await assertFocus(after: "focus left", 5)
        await assertFocus(after: "focus right", 1)
        await assertFocus(after: "focus right", 4)
        // Nothing to the right of the right stack
        await assertFocus(after: "focus right", 4)
    }

    @Test func testCenterFocusWithinStacks() async {
        setUpCenterMaster(focused: 5)
        await assertFocus(after: "focus up", 3)
        await assertFocus(after: "focus up", 3)
        await assertFocus(after: "focus right", 1)
        // The master isn't above or below anything
        await assertFocus(after: "focus down", 1)
        await assertFocus(after: "focus right", 4)
        await assertFocus(after: "focus up", 2)
        await assertFocus(after: "focus down", 4)
        await assertFocus(after: "focus down", 4)
        // The left stack remembers its most recent window
        await assertFocus(after: "focus left", 1)
        await assertFocus(after: "focus left", 3)
    }

    @Test func testCenterVerticalFocus() async {
        let root = setUpCenterMaster(focused: 1)
        root.changeOrientation(.v)
        await assertFocus(after: "focus down", 4)
        await assertFocus(after: "focus left", 2)
        await assertFocus(after: "focus up", 1)
        await assertFocus(after: "focus up", 5)
        await assertFocus(after: "focus left", 3)
    }

    @Test func testCenterBelowThreeWindowsBehavesAsStart() async {
        setUpCenterMaster(focused: 1, count: 2)
        await assertFocus(after: "focus left", 1)
        await assertFocus(after: "focus right", 2)
        await assertFocus(after: "focus left", 1)
    }

    @Test func testFocusIntoCenterMasterFromOutside() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let leftOutside = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        TestWindow.new(id: 10, parent: leftOutside)
        let master = TilingContainer(parent: root, adaptiveWeight: 1, .h, .master, index: INDEX_BIND_LAST)
        master.masterPlacement = .center
        for id: OpaqueWindowId in [1, 2, 3] {
            TestWindow.new(id: id, parent: master)
        }
        let rightOutside = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
        TestWindow.new(id: 11, parent: rightOutside)

        assertEquals(Window.get(byId: 11)?.focusWindow(), true)
        // The right side of the container is the right stack
        await assertFocus(after: "focus left", 2)
        assertEquals(Window.get(byId: 10)?.focusWindow(), true)
        await assertFocus(after: "focus right", 3)
    }

    @Test func testCenterMoveAndSwap() async {
        let root = setUpCenterMaster(focused: 5)
        // From the left stack, towards the master
        await run("move right")
        assertEquals(root.layoutDescription, .h_master([.window(5), .window(2), .window(3), .window(4), .window(1)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 5)
        // The master goes back to the left stack window it came from
        await run("move left")
        assertEquals(root.layoutDescription, .h_master([.window(1), .window(2), .window(3), .window(4), .window(5)]))
        // Within the left stack
        await run("move up")
        assertEquals(root.layoutDescription, .h_master([.window(1), .window(2), .window(5), .window(4), .window(3)]))

        assertEquals(Window.get(byId: 2)?.focusWindow(), true)
        await run("swap left")
        assertEquals(root.layoutDescription, .h_master([.window(2), .window(1), .window(5), .window(4), .window(3)]))
    }

    @Test func testCenterResize() async {
        let root = setUpCenterMaster(focused: 1, count: 3)
        root.lastAppliedLayoutVirtualRect = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        root.masterRatio = 0.5

        await run("resize width +100")
        assertEquals(root.masterRatio, 0.6)

        // Both stacks grow, so the master shrinks twice as much
        assertEquals(Window.get(byId: 3)?.focusWindow(), true)
        await run("resize width +50")
        assertEquals(root.masterRatio, 0.5)

        await run("resize width 200")
        assertEquals(root.masterRatio, 0.6)
    }

    @Test func testCenterMasterLayoutCommand() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        assertEquals(TestWindow.new(id: 1, parent: root).focusWindow(), true)
        TestWindow.new(id: 2, parent: root)
        func layoutString() -> String { toLayoutString(tc: root) }

        await run("layout center_master")
        assertEquals(root.layout, .master)
        assertEquals(root.masterPlacement, .center)
        assertEquals(layoutString(), "h_center_master")

        await run("layout master center_master")
        assertNil(root.masterPlacement)
        assertEquals(layoutString(), "h_master")

        await run("layout master center_master")
        assertEquals(layoutString(), "h_center_master")

        await run("layout v_center_master")
        assertEquals(layoutString(), "v_center_master")

        // Other layouts keep the override, like the master ratio
        await run("layout tiles")
        assertEquals(root.masterPlacement, .center)
        assertEquals(layoutString(), "v_tiles")

        await run("layout h_master")
        assertNil(root.masterPlacement)
        assertEquals(layoutString(), "h_master")

        testParseSingleCommandSucc(
            "layout h_center_master v_center_master",
            LayoutCmdArgs(rawArgs: [], toggleBetween: [.h_center_master, .v_center_master]),
        )
    }

    @Test func testMasterPlacementPerMonitor() {
        let root = setUpHMaster()
        assertEquals(root.effectiveMasterPlacement, .start)
        config.masterPlacement = .perMonitor([PerMonitorValue(description: .main, value: .center)], default: .start)
        assertEquals(root.effectiveMasterPlacement, .center)
        assertTrue(root.isMasterCentered)
        config.masterPlacement = .perMonitor([PerMonitorValue(description: .secondary, value: .center)], default: .start)
        assertEquals(root.effectiveMasterPlacement, .start)
        // The per-container override wins
        root.masterPlacement = .center
        assertEquals(root.effectiveMasterPlacement, .center)
        // The monitor-level center isn't reported by the layout string, the override is
        assertEquals(toLayoutString(tc: root), "h_center_master")
    }

    @Test func testMasterPlacementConfig() {
        assertEquals(parseConfig("").config.masterPlacement, .constant(.start))
        assertEquals(parseConfig("master-placement = 'center'").config.masterPlacement, .constant(.center))
        let result = parseConfig("master-placement = [{ monitor.'Tempest' = 'center' }, 'start']")
        assertEquals(result.strErrors, [])
        assertEquals(result.config.masterPlacement, .perMonitor([PerMonitorValue(description: .pattern("Tempest")!, value: .center)], default: .start))
        assertEquals(
            parseConfig("master-placement = 'middle'").strErrors,
            ["[ERROR] master-placement: Can't parse master placement 'middle'. Possible values: start, center"],
        )
        assertEquals(
            parseConfig("master-placement = [{ monitor.main = 'middle' }, 'start']").strErrors,
            ["[ERROR] master-placement: Can't parse master placement 'middle'. Possible values: start, center"],
        )
    }

    // ===================================================== master-new-window

    /// Places window 5 into `h_master [1 (master), 2, 3 (focused), 4]`
    private func placeNewWindow(_ workspace: Workspace) -> TilingContainer {
        let root = workspace.rootTilingContainer
        root.layout = .master
        for id: OpaqueWindowId in [1, 2, 3, 4] {
            TestWindow.new(id: id, parent: root)
        }
        assertEquals(Window.get(byId: 3)?.focusWindow(), true)
        let data = NewWindowParentKind.tiling.unbindAndGetBindingData(workspace, window: nil)
        TestWindow.new(id: 5, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        return root
    }

    @Test func testMasterNewWindow() {
        let expected: [MasterNewWindow: [LayoutDescription]] = [
            .afterFocused: [.window(1), .window(2), .window(3), .window(5), .window(4)],
            .stackTop: [.window(1), .window(5), .window(2), .window(3), .window(4)],
            .stackBottom: [.window(1), .window(2), .window(3), .window(4), .window(5)],
            .master: [.window(5), .window(1), .window(2), .window(3), .window(4)],
        ]
        for (placement, children) in expected {
            setUpWorkspacesForTests()
            config.masterNewWindow = placement
            assertEquals(placeNewWindow(Workspace.get(byName: name)).layoutDescription, .h_master(children), additionalMsg: placement.rawValue)
        }
    }

    @Test func testMasterNewWindowIsIgnoredOutsideMaster() {
        config.masterNewWindow = .master
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        TestWindow.new(id: 3, parent: root)
        assertEquals(window2.focusWindow(), true)
        let data = NewWindowParentKind.tiling.unbindAndGetBindingData(workspace, window: nil)
        TestWindow.new(id: 4, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(4), .window(3)]))
    }

    @Test func testMasterNewWindowPerWorkspace() {
        config.workspaceRules = ["G": WorkspaceRule(masterNewWindow: .stackBottom)]
        assertEquals(placeNewWindow(Workspace.get(byName: "G")).layoutDescription, .h_master([
            .window(1), .window(2), .window(3), .window(4), .window(5),
        ]))
        setUpWorkspacesForTests()
        config.workspaceRules = ["G": WorkspaceRule(masterNewWindow: .stackBottom)]
        // The other workspaces keep the global 'after-focused'
        assertEquals(placeNewWindow(Workspace.get(byName: name)).layoutDescription, .h_master([
            .window(1), .window(2), .window(3), .window(5), .window(4),
        ]))
    }

    @Test func testMasterNewWindowConfig() {
        assertEquals(parseConfig("").config.masterNewWindow, .afterFocused)
        let result = parseConfig(
            """
            master-new-window = 'stack-top'
            [workspace.G]
                master-new-window = 'master'
            """,
        )
        assertEquals(result.strErrors, [])
        assertEquals(result.config.masterNewWindow, .stackTop)
        assertEquals(result.config.workspaceRules["G"]?.masterNewWindow, .master)
        assertEquals(
            parseConfig("master-new-window = 'top'").strErrors,
            ["[ERROR] master-new-window: Can't parse master new window 'top'. Possible values: after-focused, stack-top, stack-bottom, master"],
        )
    }

    @Test func testDwindleDoesNotSplitInsideMaster() {
        let workspace = Workspace.get(byName: name)
        setUpHMaster(focused: 2)
        assertNil(workspace.unbindAndGetBindingDataForDwindleSplit())
    }
}

extension Rect {
    fileprivate var components: [CGFloat] { [topLeftX, topLeftY, width, height] }
}
