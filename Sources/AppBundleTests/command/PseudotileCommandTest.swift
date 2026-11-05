@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct PseudotileCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        testParseSingleCommandSucc("pseudotile", PseudotileCmdArgs(rawArgs: []))
        testParseSingleCommandSucc("pseudotile on --fail-if-noop", PseudotileCmdArgs(rawArgs: []).with(\.toggle, .on).with(\.failIfNoop, true))
        testParseCommandFail("pseudotile --fail-if-noop", msg: "--fail-if-noop requires 'on' or 'off' argument", exitCode: 2)
        testParseCommandFail("pseudotile on off", msg: "ERROR: Unknown argument 'off'", exitCode: 2)
    }

    @Test func testToggleSeedsTheSizeFromTheLastFloatingSize() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer, rect: rect(0, 0, 1920, 1080))
        window.lastFloatingSize = CGSize(width: 800, height: 600)
        assertEquals(window.focusWindow(), true)

        assertEquals(await run("pseudotile").exitCode.rawValue, 0)
        assertEquals(window.isPseudoTiled, true)
        assertEquals(window.pseudoSize, CGSize(width: 800, height: 600))

        assertEquals(await run("pseudotile").exitCode.rawValue, 0)
        assertEquals(window.isPseudoTiled, false)
        assertEquals(window.pseudoSize, CGSize(width: 800, height: 600)) // Remembered for the next time
    }

    @Test func testOnSeedsTheSizeFromTheAxSize() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer, rect: rect(0, 0, 700, 500))
        let result = await run("pseudotile on --window-id 1")
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(window.isPseudoTiled, true)
        assertEquals(window.pseudoSize, CGSize(width: 700, height: 500))
    }

    @Test func testNoop() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer, rect: rect(0, 0, 700, 500))
        assertEquals(window.focusWindow(), true)

        let off = await run("pseudotile off")
        assertEquals(off.exitCode.rawValue, 0)
        assertEquals(off.stderr, ["Already not pseudotiled. Tip: use --fail-if-noop to exit with non-zero code"])
        assertEquals(await run("pseudotile off --fail-if-noop").exitCode.rawValue, 2)
        assertNil(window.pseudoSize)
    }

    @Test func testNoWindow() async {
        let result = await run("pseudotile")
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, [noWindowIsFocused])
    }

    @Test func testOnWindowDetectedRule() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, rect: rect(0, 0, 100, 100))
        let detected = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, rect: rect(0, 0, 640, 480))
        assertEquals(focused.focusWindow(), true)
        config.onWindowDetected = [
            WindowDetectedCallback(matcher: .command(.empty), rawRun: parseCommand("pseudotile on").cmdOrDie),
        ]

        await runOnWindowDetected(ifConventional: detected)
        assertEquals(detected.isPseudoTiled, true)
        assertEquals(detected.pseudoSize, CGSize(width: 640, height: 480))
        assertEquals(focused.isPseudoTiled, false)
    }

    private func run(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Rect {
    Rect(topLeftX: x, topLeftY: y, width: width, height: height)
}
