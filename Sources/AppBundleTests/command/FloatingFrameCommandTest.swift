@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FloatingFrameCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        testParseSingleCommandSucc(
            "floating-frame --size 60%x70% --center",
            FloatingFrameCmdArgs(rawArgs: [], center: true, size: .init(width: .percent(60), height: .percent(70))),
        )
        testParseSingleCommandSucc(
            "floating-frame --size 800x50% --position 0,10%",
            FloatingFrameCmdArgs(
                rawArgs: [],
                size: .init(width: .pixels(800), height: .percent(50)),
                position: .init(x: .pixels(0), y: .percent(10)),
            ),
        )
        testParseSingleCommandSucc("floating-frame --center", FloatingFrameCmdArgs(rawArgs: [], center: true))
        assertNil(parseCommand("floating-frame --window-id 1 --position 100,100").errorOrNil)

        testParseCommandFail(
            "floating-frame",
            msg: "At least one of --size, --position or --center is required",
            exitCode: 2,
        )
        testParseCommandFail(
            "floating-frame --center --position 0,0",
            msg: "ERROR: Conflicting flags: --center, --position",
            exitCode: 2,
        )
        testParseCommandFail(
            "floating-frame --size 60%",
            msg: "ERROR: Failed to parse '60%' CLI argument: Expected format: <width>x<height>",
            exitCode: 2,
        )
        testParseCommandFail(
            "floating-frame --size 0x100",
            msg: "ERROR: Failed to parse '0x100' CLI argument: '0' must be greater than zero",
            exitCode: 2,
        )
        testParseCommandFail(
            "floating-frame --size 101%x100",
            msg: "ERROR: Failed to parse '101%x100' CLI argument: '101%' must not exceed 100%",
            exitCode: 2,
        )
        testParseCommandFail(
            "floating-frame --position 1.5,0",
            msg: "ERROR: Failed to parse '1.5,0' CLI argument: '1.5' must be a non-negative integer, optionally followed by '%'",
            exitCode: 2,
        )
        testParseCommandFail(
            "floating-frame --position 10",
            msg: "ERROR: Failed to parse '10' CLI argument: Expected format: <x>,<y>",
            exitCode: 2,
        )
        testParseCommandFail(
            "floating-frame --size",
            msg: "ERROR: '--size' must be followed by '<width>x<height>'",
            exitCode: 2,
        )
    }

    @Test func testSizeInPercentAndCenter() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer, rect: rect(0, 0, 100, 100))
        assertEquals(window.focusWindow(), true)

        try await assertSucc("floating-frame --size 50%x50% --center")
        // Test monitor is 1920x1080 without gaps
        try await assertRect(window, rect(480, 270, 960, 540))
        assertEquals(window.lastFloatingSize, CGSize(width: 960, height: 540))
    }

    @Test func testSizeKeepsPosition() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer, rect: rect(100, 200, 300, 300))
        assertEquals(window.focusWindow(), true)

        try await assertSucc("floating-frame --size 800x600")
        try await assertRect(window, rect(100, 200, 800, 600))
    }

    @Test func testPositionKeepsSize() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer, rect: rect(100, 200, 300, 400))
        assertEquals(window.focusWindow(), true)

        try await assertSucc("floating-frame --position 10%,20")
        try await assertRect(window, rect(192, 20, 300, 400))
    }

    @Test func testCenterKeepsSize() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer, rect: rect(0, 0, 920, 80))
        assertEquals(window.focusWindow(), true)

        try await assertSucc("floating-frame --center")
        try await assertRect(window, rect(500, 500, 920, 80))
    }

    @Test func testClampedToMonitor() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer, rect: rect(0, 0, 100, 100))
        assertEquals(window.focusWindow(), true)

        try await assertSucc("floating-frame --size 1000x3000 --position 1500,100%")
        try await assertRect(window, rect(920, 0, 1000, 1080))
    }

    @Test func testReferenceRectRespectsOuterGaps() async throws {
        config.gaps.outer = .init(left: .constant(10), bottom: .constant(20), top: .constant(30), right: .constant(40))
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer, rect: rect(0, 0, 100, 100))
        assertEquals(window.focusWindow(), true)

        // Reference rect: x=10, y=30, width=1870, height=1030
        try await assertSucc("floating-frame --size 100%x100% --position 0,0")
        try await assertRect(window, rect(10, 30, 1870, 1030))
    }

    @Test func testWindowIdFlag() async throws {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: rect(0, 0, 100, 100))
        let target = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer, rect: rect(0, 0, 100, 100))
        assertEquals(focused.focusWindow(), true)

        try await assertSucc("floating-frame --window-id 2 --size 200x300 --position 5,6")
        try await assertRect(target, rect(5, 6, 200, 300))
        try await assertRect(focused, rect(0, 0, 100, 100))
    }

    @Test func testFailsForTilingWindow() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer, rect: rect(0, 0, 100, 100))
        assertEquals(window.focusWindow(), true)

        let result = await parseCommand("floating-frame --center").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["floating-frame only supports floating windows. Tip: use 'layout floating' first"])
        try await assertRect(window, rect(0, 0, 100, 100))
    }

    @Test func testFailsWithoutCurrentFrame() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer)
        assertEquals(window.focusWindow(), true)

        let result = await parseCommand("floating-frame --center").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["Can't get the current frame of window 1"])
    }

    @Test func testWorksWithoutCurrentFrameWhenFullySpecified() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer)
        assertEquals(window.focusWindow(), true)

        try await assertSucc("floating-frame --size 60%x70% --center")
        try await assertRect(window, rect(384, 162, 1152, 756))
    }

    @Test func testOnWindowDetectedRunsAfterLayoutFloating() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer, rect: rect(0, 0, 100, 100))
        let commands = parseCommand("layout floating; floating-frame --size 50%x50% --center").cmdOrDie
        // on-window-detected passes the detected window via the environment rather than via focus
        let result = await commands.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(window.isFloating, true)
        try await assertRect(window, rect(480, 270, 960, 540))
    }

    @Test func testProportionalPointRoundTrip() {
        let monitorRect = rect(-1920, 100, 1920, 1080)
        let point = CGPoint(x: -1000, y: 400)
        assertEquals(monitorRect.absolutePoint(fromProportional: monitorRect.proportionalPoint(point)), point)
    }
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Rect {
    Rect(topLeftX: x, topLeftY: y, width: width, height: height)
}

@MainActor
private func assertSucc(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let result = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    assertEquals(result.stderr, [], sourceLocation: sourceLocation)
    assertEquals(result.exitCode.rawValue, 0, sourceLocation: sourceLocation)
}

@MainActor
private func assertRect(_ window: Window, _ expected: Rect, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let actual = try await window.getAxRect(.nonCancellable).orDie()
    assertEquals(actual.topLeftCorner, expected.topLeftCorner, sourceLocation: sourceLocation)
    assertEquals(actual.size, expected.size, sourceLocation: sourceLocation)
}
