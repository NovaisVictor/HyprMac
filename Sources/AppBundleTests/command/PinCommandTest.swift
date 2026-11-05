@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct PinCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        testParseSingleCommandSucc("pin", PinCmdArgs(rawArgs: []))
        testParseSingleCommandSucc("pin on --fail-if-noop", PinCmdArgs(rawArgs: []).with(\.toggle, .on).with(\.failIfNoop, true))
        testParseCommandFail("pin --fail-if-noop", msg: "--fail-if-noop requires 'on' or 'off' argument", exitCode: 2)
        testParseCommandFail("pin on off", msg: "ERROR: Unknown argument 'off'", exitCode: 2)
    }

    @Test func testToggle() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)
        assertEquals(window.focusWindow(), true)

        assertEquals(await run("pin").exitCode.rawValue, 0)
        assertEquals(window.isPinned, true)
        assertEquals(await run("pin").exitCode.rawValue, 0)
        assertEquals(window.isPinned, false)
        assertTrue(window.parent === workspace.floatingWindowsContainer) // Unpinning leaves the window floating
    }

    @Test func testPinningTilingWindowFloatsIt() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        window.lastFloatingSize = CGSize(width: 800, height: 600)
        assertEquals(window.focusWindow(), true)

        assertEquals(await run("pin on").exitCode.rawValue, 0)
        assertEquals(window.isPinned, true)
        assertTrue(window.parent === workspace.floatingWindowsContainer)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))
        assertEquals(window.setAxFrameCalls.last?.size, CGSize(width: 800, height: 600))
    }

    @Test func testNoop() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer)
        assertEquals(window.focusWindow(), true)

        let off = await run("pin off")
        assertEquals(off.exitCode.rawValue, 0)
        assertEquals(off.stderr, ["Already not pinned. Tip: use --fail-if-noop to exit with non-zero code"])
        assertEquals(await run("pin off --fail-if-noop").exitCode.rawValue, 2)
        assertEquals(await run("pin on").exitCode.rawValue, 0)
        assertEquals(await run("pin on --fail-if-noop").exitCode.rawValue, 2)
    }

    @Test func testNoWindow() async {
        let result = await run("pin")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, [noWindowIsFocused])
    }

    @Test func testPinningWindowOfInvisibleWorkspaceBringsItToVisibleWorkspace() async {
        let visible = Workspace.get(byName: name)
        assertEquals(visible.focusWorkspace(), true)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "invisible").rootTilingContainer)

        assertEquals(await run("pin on --window-id 1").exitCode.rawValue, 0)
        assertTrue(window.parent === visible.floatingWindowsContainer)
    }

    @Test func testWorkspaceSwitchMovesWindowAndKeepsFocusOnMruWindowOfWorkspace() async {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        TestWindow.new(id: 1, parent: a.rootTilingContainer)
        let pinned = TestWindow.new(id: 2, parent: a.floatingWindowsContainer)
        let b3 = TestWindow.new(id: 3, parent: b.rootTilingContainer)
        TestWindow.new(id: 4, parent: b.rootTilingContainer)
        b3.markAsMostRecentChild()
        assertEquals(pinned.focusWindow(), true)
        assertEquals(await run("pin on").exitCode.rawValue, 0)

        assertEquals(await run("workspace b").exitCode.rawValue, 0)
        assertTrue(pinned.parent === b.floatingWindowsContainer)
        assertEquals(globalFocus.windowOrNil?.windowId, 3)
        assertEquals(b.mostRecentWindowRecursive?.windowId, 3)
        assertEquals(pinned.isPinned, true)

        assertEquals(await run("workspace a").exitCode.rawValue, 0)
        assertTrue(pinned.parent === a.floatingWindowsContainer)
    }

    @Test func testOnlyPreviouslyVisibleWorkspaceGivesUpPinnedWindows() {
        let a = Workspace.get(byName: "a")
        assertEquals(a.focusWorkspace(), true)
        let onA = TestWindow.new(id: 1, parent: a.floatingWindowsContainer)
        // Stands for a window pinned on another monitor, which the tests don't have
        let elsewhere = TestWindow.new(id: 2, parent: Workspace.get(byName: "elsewhere").floatingWindowsContainer)
        pinnedWindowIds = [onA.windowId, elsewhere.windowId]

        // Without the commands, which reconcile the pinned windows at the end of the session
        assertEquals(mainMonitorInfo.setVisibleWorkspace(Workspace.get(byName: "b")), true)
        assertEquals(onA.nodeWorkspace?.name, "b")
        assertEquals(elsewhere.nodeWorkspace?.name, "elsewhere")
    }

    @Test func testWorkspaceSwitchDoesntReportWindowMoved() async {
        let a = Workspace.get(byName: "a")
        assertEquals(a.focusWorkspace(), true)
        let pinned = TestWindow.new(id: 1, parent: a.floatingWindowsContainer)
        let regular = TestWindow.new(id: 2, parent: a.floatingWindowsContainer)
        pinnedWindowIds.insert(pinned.windowId)
        rememberDetectedWindowWorkspace(pinned)
        rememberDetectedWindowWorkspace(regular)
        defer { _lastKnownWindowWorkspaces = [:] }

        assertEquals(await run("workspace b").exitCode.rawValue, 0)
        assertEquals(pinned.nodeWorkspace?.name, "b")
        assertEquals(diffWindowWorkspaces([pinned, regular], &_lastKnownWindowWorkspaces), [])

        // A move that the user initiated is still reported
        assertEquals(await run("move-node-to-workspace c --window-id 1").exitCode.rawValue, 0)
        assertEquals(diffWindowWorkspaces([pinned, regular], &_lastKnownWindowWorkspaces).count, 1)
    }

    @Test func testMoveNodeToWorkspaceUnpins() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer)
        assertEquals(window.focusWindow(), true)
        assertEquals(await run("pin on").exitCode.rawValue, 0)

        assertEquals(await run("move-node-to-workspace other").exitCode.rawValue, 0)
        assertEquals(window.nodeWorkspace?.name, "other")
        assertEquals(window.isPinned, false)
    }

    @Test func testMoveNodeToWorkspaceNoopKeepsPin() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").floatingWindowsContainer)
        assertEquals(window.focusWindow(), true)
        assertEquals(await run("pin on").exitCode.rawValue, 0)

        assertEquals(await run("move-node-to-workspace a").exitCode.rawValue, 0)
        assertEquals(window.isPinned, true)
    }

    @Test func testDraggingToMonitorKeepsPin() {
        let workspace = Workspace.get(byName: name)
        assertEquals(workspace.focusWorkspace(), true)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").floatingWindowsContainer)
        pinnedWindowIds.insert(window.windowId)

        rebindFloatingWindowToMonitorUnder(window, center: CGPoint(x: 100, y: 100))
        assertTrue(window.parent === workspace.floatingWindowsContainer)
        assertEquals(window.isPinned, true)
    }

    @Test func testLayoutTilingUnpins() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer)
        assertEquals(window.focusWindow(), true)
        assertEquals(await run("pin on").exitCode.rawValue, 0)

        assertEquals(await run("layout tiling").exitCode.rawValue, 0)
        assertEquals(window.isPinned, false)
    }

    @Test func testScratchpadExclusion() async {
        let workspace = Workspace.get(byName: name)
        assertEquals(workspace.focusWorkspace(), true)
        let scratchpad = TestWindow.new(id: 1, parent: Workspace.get(byName: "home").floatingWindowsContainer)
        assertEquals(await run("scratchpad-toggle --window-id 1").exitCode.rawValue, 0)
        let pinScratchpad = await run("pin on --window-id 1")
        assertEquals(pinScratchpad.exitCode.rawValue, 2)
        assertEquals(pinScratchpad.stderr, ["Window 1 is shown by scratchpad-toggle. Hide it with scratchpad-toggle before pinning it"])
        assertEquals(scratchpad.isPinned, false)

        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        assertEquals(await run("pin on --window-id 2").exitCode.rawValue, 0)
        let toggle = await run("scratchpad-toggle --window-id 2")
        assertEquals(toggle.exitCode.rawValue, 2)
        assertEquals(toggle.stderr, ["Window 2 is pinned. Unpin it with 'pin off' before toggling it as a scratchpad"])
        assertNil(scratchpadShownWindows[2])
    }

    @Test func testCloseAllWindowsButCurrentSkipsPinnedWindows() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let pinned = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        pinnedWindowIds.insert(pinned.windowId)
        assertEquals(focused.focusWindow(), true)

        assertEquals(await run("close-all-windows-but-current").exitCode.rawValue, 0)
        assertEquals(workspace.allLeafWindowsRecursive.map(\.windowId.rawId).sorted(), [1, 3])
    }

    @Test func testReconcileRebindsPinnedWindowOfInvisibleWorkspace() {
        let visible = Workspace.get(byName: name)
        assertEquals(visible.focusWorkspace(), true)
        let stray = TestWindow.new(id: 1, parent: Workspace.get(byName: "invisible").floatingWindowsContainer)
        let tiled = TestWindow.new(id: 2, parent: visible.rootTilingContainer)
        pinnedWindowIds = [stray.windowId, tiled.windowId]

        reconcilePinnedWindows()
        assertTrue(stray.parent === visible.floatingWindowsContainer)
        assertEquals(stray.isPinned, true)
        assertEquals(tiled.isPinned, false) // Only floating windows can be pinned
    }

    @Test func testFrozenRoundTrip() {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)
        pinnedWindowIds.insert(window.windowId)
        let frozen = FrozenWorkspace(workspace).floatingWindows.singleOrNil().orDie()
        assertEquals(frozen.isPinned, true)

        pinnedWindowIds = [] // The lock screen garbage collects the window
        frozen.restoreState(of: window)
        assertEquals(window.isPinned, true)
    }

    @Test func testOnWindowDetectedRule() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        config.onWindowDetected = [
            WindowDetectedCallback(matcher: .command(.empty), rawRun: parseCommand("pin on").cmdOrDie),
        ]

        await runOnWindowDetected(ifConventional: detected)
        assertEquals(detected.isPinned, true)
        assertTrue(detected.parent === workspace.floatingWindowsContainer)
        assertEquals(focused.isPinned, false)
    }

    private func run(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
}
