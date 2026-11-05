@testable import AppBundle
import AppKit
import Common
import Testing

private let testAppId = "com.victornovais.HyprMac.test-app"

@MainActor
@Suite(.serializedGlobally)
struct ScratchpadToggleCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        assertEquals(parseCommand("scratchpad-toggle").errorOrNil, "Mandatory option is not specified (--app-bundle-id|--window-id)")
        assertTrue(parseCommand("scratchpad-toggle --app-bundle-id foo --window-id 1").errorOrNil?.contains("Conflicting flags") == true)
        testParseSingleCommandSucc("scratchpad-toggle --app-bundle-id foo", ScratchpadToggleCmdArgs(rawArgs: []).with(\.appBundleId, "foo"))
        testParseSingleCommandSucc("scratchpad-toggle --window-id 42", ScratchpadToggleCmdArgs(rawArgs: []).with(\.windowId, 42))
    }

    @Test func testShowTilingWindow() async throws {
        let home = Workspace.get(byName: "W")
        let scratchpad = TestWindow.new(id: 1, parent: home.rootTilingContainer)
        let focused = Workspace.get(byName: "a")
        let other = TestWindow.new(id: 2, parent: focused.rootTilingContainer)
        assertTrue(other.focusWindow())

        let result = await parseCommand("scratchpad-toggle --app-bundle-id \(testAppId)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])

        assertEquals(scratchpad.nodeWorkspace, focused)
        assertTrue(scratchpad.isFloating)
        assertEquals(globalFocus.windowOrNil, scratchpad)
        assertTrue(home.isEffectivelyEmpty)
        assertEquals(scratchpadShownWindows[1], ScratchpadHome(workspaceName: "W", wasFloating: false, prevFocusedWindowId: 2))
        // Centered on the 1920x1080 test monitor
        let rect = try await scratchpad.getAxRect(.nonCancellable).orDie()
        assertEquals(rect.topLeftCorner, CGPoint(x: 320, y: 180))
        assertEquals(rect.size, CGSize(width: 1280, height: 720))
    }

    @Test func testHideRestoresTilingLayoutAndFocus() async throws {
        let home = Workspace.get(byName: "W")
        let scratchpad = TestWindow.new(id: 1, parent: home.rootTilingContainer)
        TestWindow.new(id: 3, parent: home.rootTilingContainer)
        let focused = Workspace.get(byName: "a")
        let other = TestWindow.new(id: 2, parent: focused.rootTilingContainer)
        assertTrue(other.focusWindow())

        try await toggle(1)
        assertEquals(scratchpad.nodeWorkspace, focused)
        scratchpad.setAxFrame(CGPoint(x: 10, y: 20), CGSize(width: 300, height: 400)) // The user moves the scratchpad

        try await toggle(1)
        assertEquals(scratchpad.nodeWorkspace, home)
        assertTrue(scratchpad.parent is TilingContainer)
        assertEquals(home.rootTilingContainer.children.count, 2)
        assertEquals(globalFocus.windowOrNil, other)
        assertEquals(globalFocus.workspace, focused)
        assertNil(scratchpadShownWindows[1])
        assertEquals(scratchpadFrames[1], ScratchpadFrame(Rect(topLeftX: 10, topLeftY: 20, width: 300, height: 400), relativeTo: mainMonitorInfo.visibleRect))
    }

    @Test func testReshowUsesRememberedFrame() async throws {
        let scratchpad = TestWindow.new(id: 1, parent: Workspace.get(byName: "W").rootTilingContainer)
        assertTrue(Workspace.get(byName: "a").focusWorkspace())

        try await toggle(1)
        scratchpad.setAxFrame(CGPoint(x: 10, y: 20), CGSize(width: 300, height: 400))
        try await toggle(1)
        assertEquals(scratchpad.nodeWorkspace?.name, "W")
        scratchpad.setAxFrame(CGPoint(x: 0, y: 0), CGSize(width: 1920, height: 1080)) // Tiling layout on the home workspace

        assertTrue(Workspace.get(byName: "b").focusWorkspace())
        try await toggle(1)
        assertEquals(scratchpad.nodeWorkspace?.name, "b")
        let rect = try await scratchpad.getAxRect(.nonCancellable).orDie()
        assertEquals(rect.topLeftCorner, CGPoint(x: 10, y: 20))
        assertEquals(rect.size, CGSize(width: 300, height: 400))
    }

    @Test func testFloatingLayoutIsRestored() async throws {
        let scratchpad = TestWindow.new(id: 1, parent: Workspace.get(byName: "W").floatingWindowsContainer, rect: Rect(topLeftX: 5, topLeftY: 6, width: 100, height: 200))
        assertTrue(Workspace.get(byName: "a").focusWorkspace())

        try await toggle(1)
        assertTrue(scratchpad.isFloating)
        // A window that floated on its home workspace keeps its own frame
        let rect = try await scratchpad.getAxRect(.nonCancellable).orDie()
        assertEquals(rect.topLeftCorner, CGPoint(x: 5, y: 6))

        try await toggle(1)
        assertEquals(scratchpad.nodeWorkspace?.name, "W")
        assertTrue(scratchpad.isFloating)
    }

    @Test func testBringFromAnotherWorkspace() async throws {
        let scratchpad = TestWindow.new(id: 1, parent: Workspace.get(byName: "W").rootTilingContainer)
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        try await toggle(1)

        let b = Workspace.get(byName: "b")
        assertTrue(b.focusWorkspace())
        try await toggle(1)
        assertEquals(scratchpad.nodeWorkspace, b)
        assertTrue(scratchpad.isFloating)
        assertEquals(globalFocus.windowOrNil, scratchpad)
        assertEquals(scratchpadShownWindows[1]?.workspaceName, "W")

        try await toggle(1)
        assertEquals(scratchpad.nodeWorkspace?.name, "W")
        assertTrue(scratchpad.parent is TilingContainer)
        assertEquals(globalFocus.workspace, b)
    }

    @Test func testGarbageCollectedHomeWorkspaceIsRecreated() async throws {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "W").rootTilingContainer)
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        try await toggle(1)
        Workspace.garbageCollectUnusedWorkspaces()
        assertFalse(Workspace.all.map(\.name).contains("W"))

        try await toggle(1)
        assertEquals(Window.get(byId: 1)?.nodeWorkspace?.name, "W")
    }

    @Test func testWindowOnFocusedWorkspaceIsOnlyFocused() async {
        let focused = Workspace.get(byName: "W")
        let window = TestWindow.new(id: 1, parent: focused.rootTilingContainer)
        assertTrue(TestWindow.new(id: 2, parent: focused.rootTilingContainer).focusWindow())

        let result = await parseCommand("scratchpad-toggle --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, ["Window 1 already belongs to the focused workspace 'W'. Focusing it"])
        assertEquals(globalFocus.windowOrNil, window)
        assertTrue(window.parent is TilingContainer)
        assertTrue(scratchpadShownWindows.isEmpty)
    }

    @Test func testAppWithSeveralWindowsPrefersShownScratchpad() async throws {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "W").rootTilingContainer)
        let shown = TestWindow.new(id: 2, parent: Workspace.get(byName: "S").rootTilingContainer)
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        try await toggle(2)

        let result = await parseCommand("scratchpad-toggle --app-bundle-id \(testAppId)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(shown.nodeWorkspace?.name, "S")
        assertEquals(Window.get(byId: 1)?.nodeWorkspace?.name, "W")
    }

    @Test func testMissingWindow() async {
        let result = await parseCommand("scratchpad-toggle --app-bundle-id net.whatsapp.WhatsApp").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, [
            "No window of app 'net.whatsapp.WhatsApp' can be toggled as a scratchpad. " +
                "The app isn't running, has no windows, or its windows are pinned, minimized, in macOS native fullscreen or hidden",
        ])

        let byId = await parseCommand("scratchpad-toggle --window-id 42").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(byId.exitCode.rawValue, 2)
        assertEquals(byId.stderr, ["Invalid <window-id> 42 passed to --window-id"])
    }

    @Test func testClosedWindowStateIsForgotten() async throws {
        let scratchpad = TestWindow.new(id: 1, parent: Workspace.get(byName: "W").rootTilingContainer)
        let focused = Workspace.get(byName: "a")
        assertTrue(focused.focusWorkspace())
        try await toggle(1)
        try await toggle(1)
        try await toggle(1)
        assertNotNil(scratchpadShownWindows[1])
        assertNotNil(scratchpadFrames[1])

        // What MacWindow.garbageCollect does when the window is closed
        scratchpad.unbindFromParent()
        forgetScratchpadState(windowId: 1)
        assertTrue(scratchpadShownWindows.isEmpty)
        assertTrue(scratchpadFrames.isEmpty)

        // A new window that reuses the id isn't mistaken for the shown scratchpad
        let reused = TestWindow.new(id: 1, parent: Workspace.get(byName: "b").rootTilingContainer)
        try await toggle(1)
        assertEquals(reused.nodeWorkspace, focused)
        assertEquals(scratchpadShownWindows[1]?.workspaceName, "b")
    }

    @Test func testSlideInFromOffScreen() async throws {
        enableSlide()
        let scratchpad = TestWindow.new(id: 1, parent: Workspace.get(byName: "W").rootTilingContainer)
        assertTrue(Workspace.get(byName: "a").focusWorkspace())

        try await toggle(1)
        // Starts below the monitor, with the size it lands with. It doesn't flash at the target first
        assertEquals(scratchpad.frames, [Rect(topLeftX: 320, topLeftY: 1080, width: 1280, height: 720)])
        assertEquals(frameAnimator.target(of: scratchpad), centered)
        frameAnimator.tick()
        let frame = scratchpad.frames.last.orDie()
        assertEquals(frame.topLeftX, centered.topLeftX)
        assertTrue(frame.topLeftY > centered.topLeftY) // Comes from below the monitor
        assertEquals(frame.size, centered.size)
    }

    @Test func testSlideOutThenHide() async throws {
        enableSlide()
        var landed = 0
        onScratchpadSlideOutLanded = { landed += 1 }
        let home = Workspace.get(byName: "W")
        let scratchpad = TestWindow.new(id: 1, parent: home.floatingWindowsContainer, rect: Rect(topLeftX: 5, topLeftY: 6, width: 100, height: 200))
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        try await toggle(1)
        let shown = Rect(topLeftX: 5, topLeftY: 6, width: 100, height: 200)
        assertNil(frameAnimator.target(of: scratchpad)) // The first show of a floating window keeps its frame

        try await toggle(1)
        // The tree is final right away. Only the window is still on the screen, sliding out
        assertEquals(scratchpad.nodeWorkspace?.name, "W")
        assertEquals(frameAnimator.target(of: scratchpad), Rect(topLeftX: 5, topLeftY: 1080, width: 100, height: 200))
        assertEquals(scratchpad.frameToUnhide, shown) // Not the off-screen frame the slide lands on
        assertEquals(landed, 0)
        frameAnimator.finish(scratchpad)
        assertEquals(landed, 1)

        // The next show restores the frame
        try await toggle(1)
        assertEquals(frameAnimator.target(of: scratchpad), shown)
        assertNil(scratchpad.frameToUnhide)
    }

    @Test func testToggleMidSlideRetargets() async throws {
        enableSlide()
        var landed = 0
        onScratchpadSlideOutLanded = { landed += 1 }
        let scratchpad = TestWindow.new(id: 1, parent: Workspace.get(byName: "W").rootTilingContainer)
        assertTrue(Workspace.get(byName: "a").focusWorkspace())

        try await toggle(1) // Slides in
        try await toggle(1) // Slides out before it's in
        assertEquals(scratchpad.nodeWorkspace?.name, "W")
        assertEquals(frameAnimator.target(of: scratchpad)?.topLeftY, 1080)
        // Remembered where the slide in would have landed, not where it was interrupted
        assertEquals(scratchpadFrames[1], ScratchpadFrame(centered, relativeTo: mainMonitorInfo.visibleRect))

        try await toggle(1) // Comes back before it's out
        assertEquals(frameAnimator.target(of: scratchpad), centered)
        frameAnimator.finish(scratchpad)
        assertEquals(landed, 0) // The slide out was retargeted, so its completion was dropped
        assertEquals(scratchpad.nodeWorkspace?.name, "a")
    }

    @Test func testFrameWriteDropsTheSlideOutCompletion() async throws {
        enableSlide()
        var landed = 0
        onScratchpadSlideOutLanded = { landed += 1 }
        let scratchpad = TestWindow.new(id: 1, parent: Workspace.get(byName: "W").rootTilingContainer)
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        try await toggle(1)
        frameAnimator.finish(scratchpad)
        try await toggle(1)
        assertNotNil(frameAnimator.target(of: scratchpad))

        scratchpad.setAxFrame(CGPoint(x: 0, y: 0), nil) // E.g. the layout of the home workspace once it's shown
        frameAnimator.finish(scratchpad)
        assertEquals(landed, 0)
    }

    @Test func testNoSlideByDefault() async throws {
        let scratchpad = TestWindow.new(id: 1, parent: Workspace.get(byName: "W").rootTilingContainer)
        assertTrue(Workspace.get(byName: "a").focusWorkspace())
        try await toggle(1)
        assertNil(frameAnimator.target(of: scratchpad))
        assertEquals(scratchpad.frames, [centered])
        try await toggle(1)
        assertNil(frameAnimator.target(of: scratchpad))
    }

    private func enableSlide() {
        config.animations.scratchpad.enabled = true
        // Long enough for the assertions on the frames of a running slide not to depend on the speed of the machine
        config.animations.scratchpad.durationMs = 1000
    }

    /// Where the scratchpad lands on the 1920x1080 test monitor
    private let centered = Rect(topLeftX: 320, topLeftY: 180, width: 1280, height: 720)

    private func toggle(_ windowId: UInt32, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let result = await parseCommand("scratchpad-toggle --window-id \(windowId)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0, sourceLocation: sourceLocation)
        assertEquals(result.stderr, [], sourceLocation: sourceLocation)
    }
}
