@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct PreselectCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testPreselectAndCancel() async {
        let window1 = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        assertEquals(window1.focusWindow(), true)

        assertEquals(await parseCommand("preselect up").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 0)
        assertEquals(window1.preselect, .up)
        assertEquals(await parseCommand("preselect cancel").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 0)
        assertNil(window1.preselect)
        // Nothing to cancel is fine
        assertEquals(await parseCommand("preselect cancel").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 0)
    }

    @Test func testFocusChangeKeepsPreselect() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        assertEquals(window1.focusWindow(), true)

        await parseCommand("preselect left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window2.focusWindow(), true)
        assertEquals(window1.preselect, .left)
    }

    @Test func testPreselectWithWindowId() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        assertEquals(TestWindow.new(id: 1, parent: root).focusWindow(), true)
        let window2 = TestWindow.new(id: 2, parent: root)

        await parseCommand("preselect --window-id 2 down").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window2.preselect, .down)
    }

    @Test func testPreselectFailsInMaster() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        root.layout = .master
        let window1 = TestWindow.new(id: 1, parent: root)
        assertEquals(window1.focusWindow(), true)

        let result = await parseCommand("preselect up").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["The parent container of the window has 'master' layout. Only 'tiles' containers can be split"])
        assertNil(window1.preselect)
    }

    @Test func testPreselectFailsForFloatingWindow() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer)
        assertEquals(window.focusWindow(), true)

        let result = await parseCommand("preselect up").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertNil(window.preselect)
    }

    @Test func testParse() {
        assertEquals(parseCommand("preselect").errorOrNil, "ERROR: Argument '(left|down|up|right|cancel)' is mandatory")
    }
}
