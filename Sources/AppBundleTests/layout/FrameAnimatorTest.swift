@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FrameAnimatorTest {
    init() { setUpWorkspacesForTests() }

    @Test func testEasingEndpointsAndMonotonicity() {
        for curve in AnimationCurve.builtIns.values {
            assertEquals(curve.easing.progress(0), 0)
            assertEquals(curve.easing.progress(1), 1)
            assertEquals(curve.easing.progress(-1), 0)
            assertEquals(curve.easing.progress(2), 1)
            let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { curve.easing.progress(CGFloat($0)) }
            assertEquals(samples, samples.sorted())
        }
        assertEquals(Easing.linear.progress(0.3), 0.3)
    }

    @Test func testBezierMatchesCss() {
        // CSS `ease`
        let ease = Easing.bezier(CubicBezier(0.25, 0.1, 0.25, 1))
        assertTrue(abs(ease.progress(0.5) - 0.8024) < 0.001)
        // Today's feel: close to the cubic ease-out the animator used to hard-code
        let easeOut = AnimationCurve.easeOut.easing
        for time in stride(from: 0.0, through: 1.0, by: 0.1) {
            let remaining = 1 - time
            assertTrue(abs(easeOut.progress(CGFloat(time)) - CGFloat(1 - remaining * remaining * remaining)) < 0.02)
        }
    }

    @Test func testBezierMayOvershoot() {
        let overshoot = Easing.bezier(CubicBezier(0.05, 0.9, 0.1, 1.5))
        let peak = stride(from: 0.0, through: 1.0, by: 0.01).lazy.map { overshoot.progress(CGFloat($0)) }.max().orDie()
        assertTrue(peak > 1)
        assertEquals(overshoot.progress(1), 1)
        // A size never collapses, whatever the curve
        let rect = interpolatedRect(from: rectA, to: Rect(topLeftX: 0, topLeftY: 0, width: 10, height: 10), progress: 1.5)
        assertEquals(rect.width, 1)
    }

    @Test func testInterpolatedRect() {
        let from = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)
        let to = Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 100)
        assertEquals(interpolatedRect(from: from, to: to, progress: 0), from)
        assertEquals(interpolatedRect(from: from, to: to, progress: 0.5), Rect(topLeftX: 50, topLeftY: 100, width: 200, height: 100))
        assertEquals(interpolatedRect(from: from, to: to, progress: 1), to)
    }

    @Test func testAnimationLandsExactlyOnTarget() {
        let clock = FakeClock()
        let animator = FrameAnimator(now: { clock.now }, isTickingAutomatically: false)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)

        animator.animate(window, from: rectA, to: rectB, style)
        assertEquals(window.frames, []) // Frames come from ticks only
        assertEquals(animator.target(of: window), rectB)

        clock.advance(.milliseconds(50))
        animator.tick()
        assertEquals(window.frames, [interpolatedRect(from: rectA, to: rectB, progress: AnimationCurve.easeOut.easing.progress(0.5))])

        clock.advance(.milliseconds(60))
        animator.tick()
        assertEquals(window.frames.last, rectB)
        assertNil(animator.target(of: window))

        animator.tick()
        assertEquals(window.frames.count, 2)
    }

    @Test func testRetargetStartsFromCurrentRect() {
        let clock = FakeClock()
        let animator = FrameAnimator(now: { clock.now }, isTickingAutomatically: false)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)

        animator.animate(window, from: rectA, to: rectB, style)
        clock.advance(.milliseconds(50))
        animator.tick()
        let current = window.frames.last.orDie()

        // `from` is ignored: the window is mid-way, and must not jump back
        animator.animate(window, from: rectA, to: rectC, style)
        assertEquals(animator.target(of: window), rectC)
        animator.tick()
        assertEquals(window.frames.last, current)

        clock.advance(.milliseconds(100))
        animator.tick()
        assertEquals(window.frames.last, rectC)
        assertNil(animator.target(of: window))
    }

    @Test func testSameTargetDoesNotRestartTheAnimation() {
        let clock = FakeClock()
        let animator = FrameAnimator(now: { clock.now }, isTickingAutomatically: false)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)

        animator.animate(window, from: rectA, to: rectB, style)
        clock.advance(.milliseconds(60))
        animator.animate(window, from: rectC, to: rectB, style)
        clock.advance(.milliseconds(50))
        animator.tick()
        assertEquals(window.frames, [rectB])
    }

    @Test func testWindowJumpsWithoutPreviousRect() {
        let animator = FrameAnimator(now: { ContinuousClock.now }, isTickingAutomatically: false)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)

        animator.animate(window, from: nil, to: rectA, style)
        animator.animate(window, from: rectA, to: rectA, style)
        animator.animate(window, from: rectA, to: rectB, FrameAnimationStyle(duration: .zero, easing: .linear))
        assertEquals(window.frames, [rectA, rectA, rectB])
        assertNil(animator.target(of: window))
    }

    @Test func testCancelAndFinish() {
        let clock = FakeClock()
        let animator = FrameAnimator(now: { clock.now }, isTickingAutomatically: false)
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)

        animator.animate(window1, from: rectA, to: rectB, style)
        animator.animate(window2, from: rectA, to: rectB, style)
        animator.cancel(window1)
        animator.finish(window2)
        clock.advance(.milliseconds(50))
        animator.tick()
        assertEquals(window1.frames, [])
        assertEquals(window2.frames, [rectB])
    }

    @Test func testClosedWindowIsDropped() {
        let clock = FakeClock()
        let animator = FrameAnimator(now: { clock.now }, isTickingAutomatically: false)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)

        animator.animate(window, from: rectA, to: rectB, style)
        window.unbindFromParent()
        clock.advance(.milliseconds(50))
        animator.tick()
        assertEquals(window.frames, [])
        assertNil(animator.target(of: window))
    }

    @Test func testAnyOtherFrameWriteCancelsTheAnimation() {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        frameAnimator.animate(window, from: rectA, to: rectB, style)
        assertEquals(frameAnimator.target(of: window), rectB)

        window.setAxFrame(rectC.topLeftCorner, nil)
        assertNil(frameAnimator.target(of: window))
    }

    @Test func testAnimatedLayout() async throws {
        config.mouseGrab.livePreview = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        let left = window1.lastAppliedLayoutPhysicalRect.orDie()
        let right = window2.lastAppliedLayoutPhysicalRect.orDie()
        assertEquals(window1.frames, [left])

        swapWindows(mruDominant: window1, window2)
        try await workspace.layoutWorkspace(animation: .mouseGrab)
        assertEquals(window1.frames, [left]) // No jump, the animator moves the windows
        assertEquals(frameAnimator.target(of: window1), right)
        assertEquals(frameAnimator.target(of: window2), left)
        assertEquals(window1.lastAppliedLayoutPhysicalRect, right) // The hit-test sees the target right away

        // A regular layout that agrees with the animation lets it land
        try await workspace.layoutWorkspace()
        assertEquals(window1.frames, [left])
        assertEquals(frameAnimator.target(of: window1), right)

        // A regular layout that puts the window elsewhere wins
        let window3 = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()
        assertNil(frameAnimator.target(of: window1))
        assertNil(frameAnimator.target(of: window2))
        assertEquals(window1.frames.last, window1.lastAppliedLayoutPhysicalRect)
        assertEquals(window3.frames.count, 1)
    }

    @Test func testAnimatedLayoutIsImmediateByDefault() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        swapWindows(mruDominant: window1, window2)

        try await workspace.layoutWorkspace(animation: .mouseGrab)
        assertEquals(window1.frames.count, 2)
        assertEquals(window1.frames.last, window1.lastAppliedLayoutPhysicalRect)
        assertNil(frameAnimator.target(of: window1))

        config.mouseGrab.livePreview = true
        config.animations.mouseGrab.durationMs = 0
        swapWindows(mruDominant: window1, window2)
        try await workspace.layoutWorkspace(animation: .mouseGrab)
        assertEquals(window1.frames.count, 3)
        assertNil(frameAnimator.target(of: window1))
    }

    @Test func testSessionPolicy() {
        assertEquals(RefreshSessionEvent.startup.layoutAnimation, .none)
        assertEquals(RefreshSessionEvent.configAutoReload.layoutAnimation, .none)
        assertEquals(RefreshSessionEvent.focusFollowsMouse.layoutAnimation, .none)
        assertEquals(RefreshSessionEvent.globalObserverLeftMouseUp.layoutAnimation, .none)
        assertEquals(RefreshSessionEvent.resetManipulatedWithMouse.layoutAnimation, .none)
        assertEquals(RefreshSessionEvent.globalObserver(NSWorkspace.activeSpaceDidChangeNotification.rawValue).layoutAnimation, .none)
        assertEquals(RefreshSessionEvent.globalObserver(NSWorkspace.didTerminateApplicationNotification.rawValue).layoutAnimation, .windowsMove)
        assertEquals(RefreshSessionEvent.hotkeyBinding.layoutAnimation, .windowsMove)
        assertEquals(RefreshSessionEvent.menuBarButton.layoutAnimation, .windowsMove)
        assertEquals(RefreshSessionEvent.ax("AXWindowCreated").layoutAnimation, .windowsMove)
        assertEquals(RefreshSessionEvent.socketServer(BalanceSizesCmdArgs(rawArgs: [])).layoutAnimation, .windowsMove)
        assertEquals(RefreshSessionEvent.mouseGrab.layoutAnimation, .mouseGrab)
    }

    @Test func testWindowsMoveIsOffByDefault() async throws {
        let (workspace, window1, window2) = try await setUpTwoWindows()
        swapWindows(mruDominant: window1, window2)
        try await workspace.layoutWorkspace(animation: .windowsMove)
        assertEquals(window1.frames.count, 2)
        assertNil(frameAnimator.target(of: window1))
    }

    @Test func testWindowsMoveAnimatesWhenEnabled() async throws {
        config.animations.windowsMove.enabled = true
        let (workspace, window1, window2) = try await setUpTwoWindows()
        let left = window1.lastAppliedLayoutPhysicalRect.orDie()
        let right = window2.lastAppliedLayoutPhysicalRect.orDie()
        swapWindows(mruDominant: window1, window2)
        try await workspace.layoutWorkspace(animation: .windowsMove)
        assertEquals(window1.frames, [left])
        assertEquals(frameAnimator.target(of: window1), right)
        assertEquals(frameAnimator.target(of: window2), left)

        // Not during a native drag
        frameAnimator.cancelAll()
        currentlyManipulatedWithMouseWindowId = window2.windowId
        defer { currentlyManipulatedWithMouseWindowId = nil }
        swapWindows(mruDominant: window1, window2)
        try await workspace.layoutWorkspace(animation: .windowsMove)
        assertNil(frameAnimator.target(of: window1))
    }

    @Test func testWindowWithoutPreviousSlotJumps() async throws {
        config.animations.windowsMove.enabled = true
        let (workspace, window1, window2) = try await setUpTwoWindows()
        // What hideInCorner does to the windows of a hidden workspace
        window1.lastAppliedLayoutPhysicalRect = nil
        swapWindows(mruDominant: window1, window2)
        try await workspace.layoutWorkspace(animation: .windowsMove)
        assertNil(frameAnimator.target(of: window1))
        assertEquals(window1.frames.last, window1.lastAppliedLayoutPhysicalRect)
        assertNotNil(frameAnimator.target(of: window2))
    }

    @Test func testWindowFromAnotherMonitorJumps() async throws {
        config.animations.windowsMove.enabled = true
        let (workspace, window1, window2) = try await setUpTwoWindows()
        window1.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 3000, topLeftY: 0, width: 500, height: 500)
        try await workspace.layoutWorkspace(animation: .windowsMove)
        assertNil(frameAnimator.target(of: window1))
        assertNil(frameAnimator.target(of: window2)) // Didn't move
    }

    @Test func testNoAnimationWhenTheWorkspaceRectChanges() async throws {
        config.animations.windowsMove.enabled = true
        let (workspace, window1, _) = try await setUpTwoWindows()
        config.gaps = Gaps(inner: .zero, outer: Gaps.Outer(left: 10, bottom: 10, top: 10, right: 10))
        try await workspace.layoutWorkspace(animation: .windowsMove)
        assertNil(frameAnimator.target(of: window1))
        assertEquals(window1.frames.last?.topLeftCorner, CGPoint(x: 10, y: 10))

        // The next layout with the same rect animates again
        try await workspace.layoutWorkspace(animation: .windowsMove)
        let window3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace(animation: .windowsMove)
        assertNotNil(frameAnimator.target(of: window1))
        assertNil(frameAnimator.target(of: window3)) // A new window has no previous slot
    }

    @Test func testFloatingWindowsNeverAnimate() async throws {
        config.animations.windowsMove.enabled = true
        let workspace = Workspace.get(byName: name)
        let floating = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: rectA)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace(animation: .windowsMove)
        floating.isFullscreen = true
        try await workspace.layoutWorkspace(animation: .windowsMove)
        assertNil(frameAnimator.target(of: floating))
        assertEquals(floating.frames.last, mainMonitorInfo.visibleRect)
    }

    @Test func testPositionOnlyWhenTheSizeDoesNotChange() {
        let clock = FakeClock()
        let animator = FrameAnimator(now: { clock.now }, isTickingAutomatically: false)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        let moved = Rect(topLeftX: 200, topLeftY: 0, width: rectA.width, height: rectA.height)

        animator.animate(window, from: rectA, to: moved, style)
        clock.advance(.milliseconds(50))
        animator.tick()
        assertNotNil(window.setAxFrameCalls.last?.topLeft)
        assertNil(window.setAxFrameCalls.last?.size)

        clock.advance(.milliseconds(50))
        animator.tick()
        assertEquals(window.setAxFrameCalls.last?.size, moved.size) // Lands exactly in the slot
        assertEquals(window.frames.last, moved)
    }

    @Test func testAnimateSizeFalseAppliesTheSizeAtTheEnd() {
        let clock = FakeClock()
        let animator = FrameAnimator(now: { clock.now }, isTickingAutomatically: false)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        let positionOnly = FrameAnimationStyle(duration: .milliseconds(100), easing: .linear, animatesSize: false)

        animator.animate(window, from: rectA, to: rectB, positionOnly)
        clock.advance(.milliseconds(50))
        animator.tick()
        assertEquals(window.setAxFrameCalls.last?.topLeft, CGPoint(x: 50, y: 100))
        assertNil(window.setAxFrameCalls.last?.size)

        // A retarget starts from the size the window really has
        animator.animate(window, from: nil, to: rectC, positionOnly)
        clock.advance(.milliseconds(50))
        animator.tick()
        assertNil(window.setAxFrameCalls.last?.size)

        clock.advance(.milliseconds(50))
        animator.tick()
        assertEquals(window.setAxFrameCalls.last?.size, rectC.size)
        assertEquals(window.setAxFrameCalls.count, 3)
    }

    @Test func testTooManyMovesJump() async throws {
        config.animations.windowsMove.enabled = true
        config.animations.maxWindows = 2
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let windows = (1 ... 3).map { TestWindow.new(id: OpaqueWindowId(UInt64($0)), parent: root) }
        try await workspace.layoutWorkspace()

        swapWindows(mruDominant: windows[0], windows[1])
        try await workspace.layoutWorkspace(animation: .windowsMove)
        assertNotNil(frameAnimator.target(of: windows[0]))
        assertNotNil(frameAnimator.target(of: windows[1]))

        // 3 moves: window 1 and 2 retarget, and window 3 starts. Above the cap, all of them jump
        windows[2].unbindFromParent()
        windows[2].bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: 0)
        try await workspace.layoutWorkspace(animation: .windowsMove)
        for window in windows {
            assertNil(frameAnimator.target(of: window))
            assertEquals(window.frames.last, window.lastAppliedLayoutPhysicalRect)
        }
    }

    @Test func testWindowsMoveForCommands() async throws {
        config.animations.windowsMove.enabled = true
        func check(_ command: String, setUp: (TilingContainer) -> [TestWindow], expectedMoves: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            setUpWorkspacesForTests()
            config.animations.windowsMove.enabled = true
            let workspace = Workspace.get(byName: name)
            let windows = setUp(workspace.rootTilingContainer)
            try await workspace.layoutWorkspace()
            let rectsBefore = windows.map(\.lastAppliedLayoutPhysicalRect)
            let writesBefore = windows.map(\.setAxFrameCalls.count)

            let result = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
            assertEquals(result.exitCode.rawValue, 0, sourceLocation: sourceLocation)
            try await workspace.layoutWorkspace(animation: .windowsMove)

            var moves = 0
            for (index, window) in windows.enumerated() {
                let rect = window.lastAppliedLayoutPhysicalRect
                if rect != rectsBefore[index] {
                    moves += 1
                    assertEquals(frameAnimator.target(of: window), rect, sourceLocation: sourceLocation)
                    assertEquals(window.setAxFrameCalls.count, writesBefore[index], sourceLocation: sourceLocation) // No jump
                } else {
                    assertNil(frameAnimator.target(of: window), sourceLocation: sourceLocation)
                }
            }
            assertEquals(moves, expectedMoves, sourceLocation: sourceLocation)
            frameAnimator.cancelAll()
        }
        func threeWindows(focus: Int) -> (TilingContainer) -> [TestWindow] {
            { root in
                let windows = (1 ... 3).map { TestWindow.new(id: OpaqueWindowId(UInt64($0)), parent: root) }
                assertTrue(windows[focus].focusWindow())
                return windows
            }
        }

        try await check("move right", setUp: threeWindows(focus: 0), expectedMoves: 2)
        try await check("swap right", setUp: threeWindows(focus: 0), expectedMoves: 2)
        try await check("resize width +100", setUp: threeWindows(focus: 0), expectedMoves: 3)
        try await check("join-with right", setUp: threeWindows(focus: 1), expectedMoves: 3)
        try await check("balance-sizes", setUp: { root in
            let windows = [TestWindow.new(id: 1, parent: root, adaptiveWeight: 3), TestWindow.new(id: 2, parent: root)]
            assertTrue(windows[0].focusWindow())
            return windows
        }, expectedMoves: 2)
        try await check("flatten-workspace-tree", setUp: { root in
            let window1 = TestWindow.new(id: 1, parent: root)
            let nested = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1)
            let windows = [window1, TestWindow.new(id: 2, parent: nested), TestWindow.new(id: 3, parent: nested)]
            assertTrue(window1.focusWindow())
            return windows
        }, expectedMoves: 3)
        // Wrapping the window into a container of the same size moves nothing
        try await check("split vertical", setUp: threeWindows(focus: 0), expectedMoves: 0)
    }

    @Test func testWindowsMoveForDwindleInsertion() async throws {
        config.animations.windowsMove.enabled = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        assertTrue(window2.focusWindow())
        try await workspace.layoutWorkspace()
        let writesBefore = window2.setAxFrameCalls.count

        let data = workspace.unbindAndGetBindingDataForDwindleSplit().orDie()
        let window3 = TestWindow.new(id: 3, parent: data.parent)
        try await workspace.layoutWorkspace(animation: .windowsMove)
        // The split window shrinks into its half, and the new window appears in the other half right away
        assertEquals(frameAnimator.target(of: window2), window2.lastAppliedLayoutPhysicalRect)
        assertEquals(window2.setAxFrameCalls.count, writesBefore)
        assertNil(frameAnimator.target(of: window3))
        assertEquals(window3.frames, [window3.lastAppliedLayoutPhysicalRect.orDie()])
        assertNil(frameAnimator.target(of: window1))
    }

    @Test func testCompletion() {
        let clock = FakeClock()
        let animator = FrameAnimator(now: { clock.now }, isTickingAutomatically: false)
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        var completions: [String] = []

        animator.animate(window, from: rectA, to: rectB, style) { completions.append("landed") }
        clock.advance(.milliseconds(50))
        animator.tick()
        assertEquals(completions, [])
        clock.advance(.milliseconds(50))
        animator.tick()
        assertEquals(completions, ["landed"])

        animator.animate(window, from: rectB, to: rectC, style) { completions.append("retargeted") }
        animator.animate(window, from: rectB, to: rectA, style)
        animator.finish(window)
        assertEquals(completions, ["landed"])

        animator.animate(window, from: rectA, to: rectB, style) { completions.append("canceled") }
        animator.cancel(window)
        animator.animate(window, from: rectA, to: rectB, style) { completions.append("written over") }
        window.setAxFrame(rectC.topLeftCorner, rectC.size)
        assertEquals(completions, ["landed"])

        animator.animate(window, from: rectA, to: rectB, style) { completions.append("finished") }
        animator.finish(window)
        assertEquals(completions, ["landed", "finished"])

        animator.animate(window, from: nil, to: rectB, style) { completions.append("jumped") }
        assertEquals(completions, ["landed", "finished", "jumped"])
    }

    @Test func testAnimatingFloatingWindowIsLeftAlone() async throws {
        // The test workspace isn't the visible one, so its floating windows are carried over to its monitor
        let workspace = Workspace.get(byName: name)
        let floating = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: rectA)
        let offScreen = Rect(topLeftX: 0, topLeftY: 5000, width: 100, height: 100)
        frameAnimator.animate(floating, from: rectA, to: offScreen, style)
        try await workspace.layoutWorkspace()
        assertEquals(frameAnimator.target(of: floating), offScreen)
        assertEquals(floating.frames, [])
    }

    private func setUpTwoWindows() async throws -> (Workspace, TestWindow, TestWindow) {
        let workspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        return (workspace, window1, window2)
    }
}

@MainActor
final class FakeClock {
    private(set) var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}

extension TestWindow {
    /// The frame after every write. A write of the position or the size only keeps the rest of the previous frame
    var frames: [Rect] {
        var frame = Rect(topLeftX: 0, topLeftY: 0, width: 0, height: 0)
        return setAxFrameCalls.map { call in
            frame = Rect(
                topLeftX: call.topLeft?.x ?? frame.topLeftX,
                topLeftY: call.topLeft?.y ?? frame.topLeftY,
                width: call.size?.width ?? frame.width,
                height: call.size?.height ?? frame.height,
            )
            return frame
        }
    }
}

private let style = FrameAnimationStyle(duration: .milliseconds(100), easing: AnimationCurve.easeOut.easing)
private let rectA = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)
private let rectB = Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 100)
private let rectC = Rect(topLeftX: 500, topLeftY: 500, width: 200, height: 200)
