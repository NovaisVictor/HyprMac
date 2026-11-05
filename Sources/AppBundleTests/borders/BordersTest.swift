@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct BordersTest {
    init() { setUpWorkspacesForTests() }

    // MARK: geometry

    @Test func testBorderWindowReachesHalfTheWidthOutsideTheWindow() {
        let window = Rect(topLeftX: 100, topLeftY: 50, width: 800, height: 600)
        assertEquals(borderFrame(around: window, width: 5, glowMargin: 0), Rect(topLeftX: 97.5, topLeftY: 47.5, width: 805, height: 605))
    }

    @Test func testGlowMarginGrowsTheBorderWindow() {
        let window = Rect(topLeftX: 100, topLeftY: 50, width: 800, height: 600)
        assertEquals(borderFrame(around: window, width: 5, glowMargin: 20), Rect(topLeftX: 77.5, topLeftY: 27.5, width: 845, height: 645))
        // Twice the blur radius, rounded up to whole points. No margin without glow
        assertEquals(borderGlowMargin(BordersConfig()), 0)
        assertEquals(borderGlowMargin(BordersConfig(glowRadius: 10)), 20)
        assertEquals(borderGlowMargin(BordersConfig(glowRadius: 7.3)), 15)
    }

    @Test func testLayerFramesWithoutGlowFillTheBorderWindow() {
        let ring = borderRing(windowRadius: 12, width: 5, placement: .belowWindow)
        let frames = borderLayerFrames(size: CGSize(width: 805, height: 605), ring: ring, width: 5, glowMargin: 0)
        assertEquals(frames.ring, CGRect(x: 0, y: 0, width: 805, height: 605))
    }

    @Test func testLayerFramesKeepTheRingAroundTheWindowInsideTheGlowMargin() {
        // An 800x600 window, width 5, glow margin 20: the border window is 845x645
        for placement in [BorderPlacement.belowWindow, .aboveWindow] {
            let ring = borderRing(windowRadius: 12, width: 5, placement: placement)
            let frames = borderLayerFrames(size: CGSize(width: 845, height: 645), ring: ring, width: 5, glowMargin: 20)
            // The ring is where it is without glow: half the width outside the window
            assertEquals(frames.ring, CGRect(x: 20, y: 20, width: 805, height: 605))
            // The glow is cast by the outer edge of the ring
            assertEquals(frames.glowShape, frames.ring)
            assertEquals(frames.glowShapeCornerRadius, 14.5)
            // The clip covers the margin and the visible ring, its inner edge is the window with its own radius
            assertEquals(frames.glowClipWidth, 22.5)
            assertEquals(frames.glowClipCornerRadius - frames.glowClipWidth, 12)
            assertEquals(CGRect(x: 0, y: 0, width: 845, height: 645).insetBy(dx: frames.glowClipWidth, dy: frames.glowClipWidth), CGRect(x: 22.5, y: 22.5, width: 800, height: 600))
        }
    }

    @Test func testGlowShapeRadiusFitsATinyWindow() {
        let ring = borderRing(windowRadius: 12, width: 5, placement: .belowWindow)
        let frames = borderLayerFrames(size: CGSize(width: 50, height: 46), ring: ring, width: 5, glowMargin: 20)
        assertEquals(frames.glowShape, CGRect(x: 20, y: 20, width: 10, height: 6))
        assertEquals(frames.glowShapeCornerRadius, 3)
    }

    @Test func testRingBelowTheWindowIsCenteredOnItsEdge() {
        let ring = borderRing(windowRadius: 12, width: 5, placement: .belowWindow)
        assertEquals(ring, BorderRing(lineWidth: 5, cornerRadius: 14.5))
        // The ring starts at the edge of the border window, half the width outside the window, so its inner half is
        // under the window. The center line of the stroke follows the corner of the window
        let outset = borderOutset(width: 5)
        assertEquals(ring.lineWidth - outset, 2.5) // Visible thickness
        assertEquals(ring.cornerRadius - ring.lineWidth / 2, 12)
    }

    @Test func testRingAboveTheWindowIsOnlyTheOuterHalf() {
        let ring = borderRing(windowRadius: 12, width: 5, placement: .aboveWindow)
        assertEquals(ring, BorderRing(lineWidth: 2.5, cornerRadius: 14.5))
        // The inner edge of the ring is the edge of the window, rounded like the window: nothing covers its content
        let outset = borderOutset(width: 5)
        assertEquals(ring.lineWidth, outset) // Visible thickness, the same as below the window
        assertEquals(ring.cornerRadius - ring.lineWidth, 12)
    }

    @Test func testCocoaFrameFlipsTheYAxis() {
        let rect = Rect(topLeftX: 95, topLeftY: 45, width: 810, height: 610)
        assertEquals(cocoaFrame(rect, mainMonitorHeight: 1080), CGRect(x: 95, y: 1080 - 655, width: 810, height: 610))
    }

    @Test func testGradientRotationIsClockwiseOnTheScreen() {
        assertEquals(gradientRotation(degrees: 0), 0)
        assertEquals(gradientRotation(degrees: 90), -.pi / 2)
        assertEquals(gradientRotation(degrees: -180), .pi)
    }

    @Test func testGradientLocationsSpanTheVisibleBand() {
        // A square seen along its side shows 1/sqrt(2) of the diagonal-wide gradient layer
        let square = gradientLocations(count: 2, size: CGSize(width: 100, height: 100), degrees: 0)
        assertEquals(square.map { ($0 * 1000).rounded() }, [146, 854])
        // Along its diagonal, the whole layer is visible
        let diagonal = gradientLocations(count: 3, size: CGSize(width: 100, height: 100), degrees: 45)
        assertEquals(diagonal.map { ($0 * 1000).rounded() }, [0, 500, 1000])
        assertEquals(gradientLocations(count: 1, size: CGSize(width: 100, height: 100), degrees: 0), [0.5])
    }

    @Test func testResampledColors() {
        let black = ArgbColor(argb: 0xFF00_0000)
        let white = ArgbColor(argb: 0xFFFF_FFFF)
        assertEquals(resampledColors([white], count: 3), Array(repeating: RgbaComponents(white), count: 3))
        assertEquals(resampledColors([black, white], count: 3).map(\.red), [0, 0.5, 1])
        assertEquals(resampledColors([black, white, black], count: 2).map(\.red), [0, 0])
        assertEquals(resampledColors([black, white], count: 2), [RgbaComponents(black), RgbaComponents(white)])
    }

    // MARK: glow

    @Test func testGlowColor() {
        let purple = ArgbColor(argb: 0xFFCB_A6F7)
        let blue = ArgbColor(argb: 0xFF89_B4FA)
        // Explicit
        assertEquals(borderGlowColor(BordersConfig(activeColor: BorderPaint(purple), glowColor: ArgbColor(argb: 0x80FF_0000))), RgbaComponents(ArgbColor(argb: 0x80FF_0000)))
        // The solid active color
        assertEquals(borderGlowColor(BordersConfig(activeColor: BorderPaint(purple))), RgbaComponents(purple))
        // The middle of a gradient
        let middle = borderGlowColor(BordersConfig(activeColor: BorderPaint(colors: [purple, blue]).orDie()))
        assertEquals(middle.red, (purple.red + blue.red) / 2)
        assertEquals(middle.green, (purple.green + blue.green) / 2)
        assertEquals(middle.blue, (purple.blue + blue.blue) / 2)
        // The middle stop of an odd gradient
        let black = ArgbColor(argb: 0xFF00_0000)
        assertEquals(borderGlowColor(BordersConfig(activeColor: BorderPaint(colors: [black, blue, black]).orDie())), RgbaComponents(blue))
    }

    @Test func testGlowIsOnlyOnTheActiveBorder() {
        assertNil(borderGlowStyle(BordersConfig(), role: .active))
        assertNil(borderGlowStyle(BordersConfig(), role: .inactive))
        let purple = ArgbColor(argb: 0xFFCB_A6F7)
        let config = BordersConfig(activeColor: BorderPaint(purple), glowRadius: 12, glowOpacity: 0.5)
        assertEquals(borderGlowStyle(config, role: .active), BorderGlowStyle(color: RgbaComponents(purple), radius: 12, opacity: 0.5))
        // The same shadow, fully transparent: a focus change only fades the opacity
        assertEquals(borderGlowStyle(config, role: .inactive), BorderGlowStyle(color: RgbaComponents(purple), radius: 12, opacity: 0))
    }

    @Test func testGlowPulse() {
        assertNil(borderGlowPulse(BordersConfig(glowRadius: 10)))
        assertNil(borderGlowPulse(BordersConfig(focusPulseMs: 300)))
        assertEquals(
            borderGlowPulse(BordersConfig(glowRadius: 10, glowOpacity: 0.5, focusPulseMs: 300)),
            BorderGlowPulse(restRadius: 10, peakRadius: 16, restOpacity: 0.5, peakOpacity: 0.75, duration: 0.3),
        )
        // The opacity can't go past 1
        assertEquals(borderGlowPulse(BordersConfig(glowRadius: 10, glowOpacity: 0.8, focusPulseMs: 300))?.peakOpacity, 1)
        // The border window leaves room for the peak of the pulse
        assertEquals(borderGlowMargin(BordersConfig(glowRadius: 10, focusPulseMs: 300)), 32)
    }

    // MARK: which windows get a border

    @Test func testActiveAndInactiveRoles() {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let tiling1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let tiling2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        assertEquals(borderRoles(focus: tiling2, showsInactive: true, isHyprMacEnabled: true), [1: .inactive, 2: .active, 3: .inactive])
        assertEquals(borderRoles(focus: floating, showsInactive: false, isHyprMacEnabled: true), [3: .active])
        assertEquals(borderRoles(focus: tiling1, showsInactive: true, isHyprMacEnabled: false), [:])
    }

    @Test func testUnconventionalWindowsHaveNoBorder() {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.macOsNativeFullscreenWindowsContainer)
        TestWindow.new(id: 3, parent: workspace.macOsNativeHiddenAppsWindowsContainer)
        TestWindow.new(id: 4, parent: macosPopupWindowsContainer)
        TestWindow.new(id: 5, parent: macosMinimizedWindowsContainer)
        let invisibleTab = TestWindow.new(id: 6, parent: workspace.rootTilingContainer)
        invisibleTab.lifeStatus = .invisible
        assertEquals(borderRoles(focus: nil, showsInactive: true, isHyprMacEnabled: true), [1: .inactive])
    }

    @Test func testWindowsOfInvisibleWorkspacesHaveNoBorder() {
        let hidden = Workspace.get(byName: name + "-hidden")
        TestWindow.new(id: 1, parent: hidden.rootTilingContainer)
        let visible = Workspace.get(byName: name)
        check(visible.focusWorkspace())
        TestWindow.new(id: 2, parent: visible.rootTilingContainer)
        assertEquals(borderRoles(focus: nil, showsInactive: true, isHyprMacEnabled: true), [2: .inactive])
    }

    @Test func testFullscreenWindowCoversTheTilingBorders() {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let fullscreen = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        fullscreen.isFullscreen = true
        fullscreen.markAsMostRecentChild()
        assertEquals(borderRoles(focus: fullscreen, showsInactive: true, isHyprMacEnabled: true), [2: .active, 3: .inactive])
    }

    // MARK: the controller

    @Test func testReconcileCreatesShowsHidesAndDisposes() {
        let server = FakeBorderWindowServer(notifiesWindowMoves: true)
        server.infos = [101: info(x: 0), 102: info(x: 500)]
        let factory = FakeOverlayFactory()
        let controller = makeController(server, factory)
        let ids: [OpaqueWindowId: UInt32] = [1: 101, 2: 102]

        controller.reconcile([1: .active, 2: .inactive], nativeWindowIds: ids)
        assertEquals(factory.made.count, 2)
        let border1 = factory.overlay(forFrameX: -2.5)
        let border2 = factory.overlay(forFrameX: 497.5)
        assertEquals(border1.ring, BorderRing(lineWidth: 5, cornerRadius: 11.5)) // The fallback radius, 9, plus 2.5
        assertEquals(border1.role, .active)
        assertEquals(border1.isShown, true)
        // Appears right below its own window, never in front of it
        assertEquals(border1.shownBelow, 101)
        assertEquals(border1.events.first, "role active animated: false") // A new border doesn't fade in
        assertEquals(border2.role, .inactive)
        // Each border is ordered right below its own window, and the windows are watched
        assertEquals(border1.reorders.last, "101 below")
        assertEquals(border2.reorders.last, "102 below")
        assertEquals(server.watched.last, [101, 102])

        // Focus moves to the second window: a transition, not a jump
        controller.reconcile([1: .inactive, 2: .active], nativeWindowIds: ids)
        assertEquals(factory.made.count, 2)
        assertEquals(border1.events.last(where: { $0.hasPrefix("role") }), "role inactive animated: true")
        assertEquals(border2.events.last(where: { $0.hasPrefix("role") }), "role active animated: true")

        // The first window goes to an invisible workspace: hidden, not disposed
        controller.reconcile([2: .active], nativeWindowIds: ids)
        assertEquals(border1.isShown, false)
        assertEquals(border1.isDisposed, false)
        assertEquals(server.watched.last, [102])

        // ... and comes back. Same border window, again right below its window
        controller.reconcile([1: .inactive, 2: .active], nativeWindowIds: ids)
        assertEquals(factory.made.count, 2)
        assertEquals(border1.isShown, true)
        assertEquals(border1.shownBelow, 101)

        // The first window is closed
        controller.reconcile([2: .active], nativeWindowIds: [2: 102])
        assertEquals(border1.isDisposed, true)

        controller.disposeAll()
        assertEquals(border2.isDisposed, true)
        assertEquals(server.watched.last, [])
    }

    @Test func testWindowServerEventsMoveTheBorder() {
        let server = FakeBorderWindowServer(notifiesWindowMoves: true)
        server.infos = [101: info(x: 0)]
        let factory = FakeOverlayFactory()
        let controller = makeController(server, factory)
        controller.reconcile([1: .active], nativeWindowIds: [1: 101])
        let border = factory.made[0]

        server.infos[101] = BorderTargetInfo(frame: Rect(topLeftX: 40, topLeftY: 0, width: 300, height: 200), level: 3)
        controller.onWindowServerEvent(.resized, 101)
        assertEquals(border.frame, CGRect(x: 37.5, y: 1080 - 202.5, width: 305, height: 205))
        assertEquals(border.level, 3) // The border takes the level of its window
        controller.onWindowServerEvent(.moved, 999) // Not a window with a border
        assertEquals(border.frame?.minX, 37.5)

        // The order of the border echoes as a reorder of its window. The border is already next to it: nothing to do
        let reordersBefore = border.reorders.count
        controller.onWindowServerEvent(.reordered, 101)
        assertEquals(border.reorders.count, reordersBefore)

        // The app raised its window over the border: the border is ordered next to it again
        server.isOrderedNextToWindow = false
        controller.onWindowServerEvent(.reordered, 101)
        assertEquals(border.reorders.count, reordersBefore + 1)
        assertEquals(border.reorders.last, "101 below")
    }

    @Test func testVerifyOrderReordersOnlyTheBordersThatLostTheirPlace() {
        let server = FakeBorderWindowServer(notifiesWindowMoves: true)
        server.placementOverride = .rightAboveWindow
        server.infos = [101: info(x: 0)]
        let factory = FakeOverlayFactory()
        let controller = makeController(server, factory)
        controller.reconcile([1: .active], nativeWindowIds: [1: 101])
        let border = factory.made[0]
        let reordersBefore = border.reorders.count

        // Still in place: nothing to do
        controller.verifyOrder()
        assertEquals(border.reorders.count, reordersBefore)

        // The app raised its window over the border after the reconcile, without a WindowServer notification
        server.isOrderedNextToWindow = false
        controller.verifyOrder()
        assertEquals(border.reorders.count, reordersBefore + 1)
        assertEquals(border.reorders.last, "101 above")
    }

    @Test func testOrderAboveShowsTheWholeStrokeRightAboveTheWindow() {
        let server = FakeBorderWindowServer(notifiesWindowMoves: true)
        server.placementOverride = .rightAboveWindow
        server.infos = [101: info(x: 0)]
        let factory = FakeOverlayFactory()
        let controller = makeController(server, factory)
        controller.reconcile([1: .active], nativeWindowIds: [1: 101])
        let border = factory.made[0]
        // The same centered stroke as below the window, so the whole width shows
        assertEquals(border.ring, BorderRing(lineWidth: 5, cornerRadius: 11.5))
        assertEquals(border.shownAbove, 101)
        assertEquals(border.shownBelow, nil)
        // Every reconcile orders it again: its app may have raised the window in the meantime
        controller.reconcile([1: .active], nativeWindowIds: [1: 101])
        assertEquals(border.reorders.last, "101 above")
    }

    @Test func testFrameWritesMoveTheBorderWithoutWindowServerEvents() {
        let server = FakeBorderWindowServer(notifiesWindowMoves: false)
        server.infos = [101: info(x: 0)]
        let factory = FakeOverlayFactory()
        let controller = makeController(server, factory)
        controller.reconcile([1: .active], nativeWindowIds: [1: 101])
        let border = factory.made[0]
        assertEquals(border.level, NSWindow.Level.floating.rawValue)
        assertEquals(border.ring, BorderRing(lineWidth: 2.5, cornerRadius: 11.5)) // Above the window: the outer half only
        // Floats above the windows: it appears in front, there is no window to order it next to
        assertEquals(border.shownBelow, nil)
        assertEquals(border.reorders, [])

        // A move without a size keeps the size
        controller.onFrameWrite(1, topLeft: CGPoint(x: 200, y: 100), size: nil)
        assertEquals(border.frame, CGRect(x: 197.5, y: 1080 - 302.5, width: 305, height: 205))
        controller.onFrameWrite(1, topLeft: nil, size: CGSize(width: 100, height: 100))
        assertEquals(border.frame, CGRect(x: 197.5, y: 1080 - 202.5, width: 105, height: 105))

        // The AX notification brings the frame that the app really applied
        controller.onAxFrameChange(101)
        assertEquals(border.frame, CGRect(x: -2.5, y: 1080 - 202.5, width: 305, height: 205))
    }

    @Test func testCornerRadiusIsReadOnCreationAndResizeOnly() {
        let server = FakeBorderWindowServer(notifiesWindowMoves: true)
        server.infos = [101: info(x: 0)]
        server.radii = [101: 16]
        let factory = FakeOverlayFactory()
        let controller = makeController(server, factory)
        controller.reconcile([1: .active], nativeWindowIds: [1: 101])
        let border = factory.made[0]
        assertEquals(server.radiusReads, [101])
        assertEquals(border.ring, BorderRing(lineWidth: 5, cornerRadius: 18.5))

        // Moves keep the cached radius, whichever way they are reported
        server.radii[101] = 20
        server.infos[101] = BorderTargetInfo(frame: Rect(topLeftX: 40, topLeftY: 10, width: 300, height: 200), level: 0)
        controller.onWindowServerEvent(.moved, 101)
        controller.onAxFrameChange(101)
        controller.reconcile([1: .inactive], nativeWindowIds: [1: 101])
        assertEquals(server.radiusReads, [101])
        assertEquals(border.ring, BorderRing(lineWidth: 5, cornerRadius: 18.5))

        // A resize reads it again
        server.infos[101] = BorderTargetInfo(frame: Rect(topLeftX: 40, topLeftY: 10, width: 400, height: 200), level: 0)
        controller.onWindowServerEvent(.resized, 101)
        assertEquals(server.radiusReads, [101, 101])
        assertEquals(border.ring, BorderRing(lineWidth: 5, cornerRadius: 22.5))

        // A window whose radius macOS can't tell gets the fallback radius
        server.infos[102] = info(x: 500)
        controller.reconcile([1: .active, 2: .inactive], nativeWindowIds: [1: 101, 2: 102])
        assertEquals(factory.overlay(forFrameX: 497.5).ring, BorderRing(lineWidth: 5, cornerRadius: 11.5))
    }

    @Test func testFixedRadiusNeverAsksTheWindowServer() {
        let server = FakeBorderWindowServer(notifiesWindowMoves: true)
        server.infos = [101: info(x: 0)]
        server.radii = [101: 16]
        let factory = FakeOverlayFactory()
        let config = BordersConfig(enabled: true, radius: .fixed(12))
        let controller = BordersController(config, windowServer: server, mainMonitorHeight: { 1080 }, makeOverlay: factory.make)
        controller.reconcile([1: .active], nativeWindowIds: [1: 101])
        server.infos[101] = BorderTargetInfo(frame: Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 200), level: 0)
        controller.onWindowServerEvent(.resized, 101)
        assertEquals(server.radiusReads, [])
        assertEquals(factory.made[0].ring, BorderRing(lineWidth: 5, cornerRadius: 14.5))
    }

    @Test func testGlowGrowsEveryBorderWindowButNotTheRing() {
        let server = FakeBorderWindowServer(notifiesWindowMoves: true)
        server.infos = [101: info(x: 0), 102: info(x: 500)]
        let factory = FakeOverlayFactory()
        let config = BordersConfig(enabled: true, glowRadius: 10)
        let controller = BordersController(config, windowServer: server, mainMonitorHeight: { 1080 }, makeOverlay: factory.make)
        controller.reconcile([1: .active, 2: .inactive], nativeWindowIds: [1: 101, 2: 102])
        // The margin is the same for both roles, so a focus change never resizes a border window
        assertEquals(factory.overlay(forFrameX: -22.5).frame, CGRect(x: -22.5, y: 1080 - 222.5, width: 345, height: 245))
        assertEquals(factory.overlay(forFrameX: 477.5).frame?.size, CGSize(width: 345, height: 245))
        assertEquals(factory.made[0].ring, BorderRing(lineWidth: 5, cornerRadius: 11.5))
    }

    @Test func testWindowGoneFromTheWindowServerHidesItsBorder() {
        let server = FakeBorderWindowServer(notifiesWindowMoves: true)
        server.infos = [101: info(x: 0)]
        let factory = FakeOverlayFactory()
        let controller = makeController(server, factory)
        controller.reconcile([1: .active], nativeWindowIds: [1: 101])
        server.infos = [:]
        controller.reconcile([1: .active], nativeWindowIds: [1: 101])
        assertEquals(factory.made[0].isShown, false)
    }

    // MARK: SkyLight

    @Test func testSkyLightSymbolsResolveOnThisMachine() {
        // A smoke test, it doesn't call anything: SkyLight may be missing on a CI runner without a WindowServer
        guard let resolver = unsafe openSkyLightResolver() else {
            withKnownIssue("SkyLight can't be opened on this machine") { throw SkyLightUnavailable() }
            return
        }
        let missing = skyLightRequiredSymbols.filter { unsafe resolver($0) == nil }
        assertEquals(missing, [])
        guard case .skyLight(let skyLight) = unsafe selectBorderWindowServer(resolver) else {
            Issue.record("SkyLight is expected to be selected")
            return
        }
        // Optional: their absence only disables the detection of the corner radius
        let missingOptional = skyLightCornerRadiusSymbols.filter { unsafe resolver($0) == nil }
        if !missingOptional.isEmpty || !skyLight.detectsCornerRadius {
            withKnownIssue("No corner radius detection. SkyLight lacks \(missingOptional)") { throw SkyLightUnavailable() }
        }
    }

    @Test func testCornerRadiusOfARealWindow() {
        guard let resolver = unsafe openSkyLightResolver(), case .skyLight(let skyLight) = unsafe selectBorderWindowServer(resolver),
              skyLight.detectsCornerRadius
        else {
            withKnownIssue("SkyLight can't detect corner radii on this machine") { throw SkyLightUnavailable() }
            return
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let windowIds = windows.filter { $0[kCGWindowLayer] as? Int == 0 }.compactMap { $0[kCGWindowNumber] as? UInt32 }
        if windowIds.isEmpty {
            withKnownIssue("No normal window on the screen") { throw SkyLightUnavailable() }
            return
        }
        for windowId in windowIds {
            // Repeated reads would crash on a wrong ownership of the CF objects of the query. A window that draws its
            // own frame may have no radius, hence nil
            let radii = (0 ..< 20).map { _ in skyLight.cornerRadius(of: windowId) }
            assertEquals(Set(radii).count, 1)
            if let radius = radii[0] { #expect(radius > 0) }
        }
        assertNil(skyLight.cornerRadius(of: UInt32.max)) // No such window
    }

    @Test func testMissingCornerRadiusSymbolsKeepSkyLight() {
        guard let resolver = unsafe openSkyLightResolver() else {
            withKnownIssue("SkyLight can't be opened on this machine") { throw SkyLightUnavailable() }
            return
        }
        let withoutRadii: SkyLightSymbolResolver = { skyLightCornerRadiusSymbols.contains($0) ? nil : unsafe resolver($0) }
        guard case .skyLight(let skyLight) = unsafe selectBorderWindowServer(withoutRadii) else {
            Issue.record("Optional symbols must not trigger the public API fallback")
            return
        }
        assertEquals(skyLight.detectsCornerRadius, false)
        assertNil(skyLight.cornerRadius(of: 1))

        // One of them is enough to disable the detection
        let withoutOne: SkyLightSymbolResolver = { $0 == "SLSWindowIteratorGetCornerRadii" ? nil : unsafe resolver($0) }
        guard case .skyLight(let partial) = unsafe selectBorderWindowServer(withoutOne) else {
            Issue.record("Optional symbols must not trigger the public API fallback")
            return
        }
        assertEquals(partial.detectsCornerRadius, false)
    }

    @Test func testFallbackWhenASymbolIsMissing() {
        guard let resolver = unsafe openSkyLightResolver() else {
            withKnownIssue("SkyLight can't be opened on this machine") { throw SkyLightUnavailable() }
            return
        }
        let withoutBounds: SkyLightSymbolResolver = { $0 == "SLSGetWindowBounds" ? nil : unsafe resolver($0) }
        guard case .publicApi(let reason) = unsafe selectBorderWindowServer(withoutBounds) else {
            Issue.record("The public API fallback is expected")
            return
        }
        assertEquals(reason, "SkyLight lacks SLSGetWindowBounds. Probably, a macOS update removed them.")

        guard case .publicApi(let noFramework) = selectBorderWindowServer(nil) else {
            Issue.record("The public API fallback is expected")
            return
        }
        assertEquals(noFramework, "Can't open \(skyLightPath).")
    }

    private func info(x: CGFloat) -> BorderTargetInfo {
        BorderTargetInfo(frame: Rect(topLeftX: x, topLeftY: 0, width: 300, height: 200), level: 0)
    }

    private func makeController(_ server: FakeBorderWindowServer, _ factory: FakeOverlayFactory) -> BordersController {
        BordersController(
            BordersConfig(enabled: true),
            windowServer: server,
            mainMonitorHeight: { 1080 },
            makeOverlay: factory.make,
            scheduleOrderVerification: { _ in }, // Tests call verifyOrder() by hand
        )
    }
}

private struct SkyLightUnavailable: Error {}

@MainActor
private final class FakeBorderWindowServer: BorderWindowServer {
    let notifiesWindowMoves: Bool
    var infos: [UInt32: BorderTargetInfo] = [:]
    private(set) var watched: [[UInt32]] = []

    var placementOverride: BorderPlacement? = nil

    init(notifiesWindowMoves: Bool) { self.notifiesWindowMoves = notifiesWindowMoves }

    var placement: BorderPlacement { placementOverride ?? (notifiesWindowMoves ? .belowWindow : .aboveWindow) }
    func targetInfo(_ windowId: UInt32) -> BorderTargetInfo? { infos[windowId] }
    var radii: [UInt32: CGFloat] = [:]
    private(set) var radiusReads: [UInt32] = []
    func cornerRadius(_ windowId: UInt32) -> CGFloat? {
        radiusReads.append(windowId)
        return radii[windowId]
    }
    var isOrderedNextToWindow = true
    func isOrderedNextTo(border: UInt32, target: UInt32) -> Bool { isOrderedNextToWindow }
    func watch(_ windowIds: [UInt32]) { watched.append(windowIds) }
}

@MainActor
private final class FakeOverlayFactory {
    private(set) var made: [FakeOverlay] = []

    func make(_: BordersConfig) -> any BorderOverlay {
        let overlay = FakeOverlay(windowNumber: 1000 + made.count)
        made.append(overlay)
        return overlay
    }

    func overlay(forFrameX x: CGFloat) -> FakeOverlay { made.first { $0.frame?.minX == x }.orDie() }
}

@MainActor
private final class FakeOverlay: BorderOverlay {
    let windowNumber: Int
    private(set) var frame: CGRect?
    private(set) var ring: BorderRing?
    private(set) var level: Int?
    private(set) var role: BorderRole?
    private(set) var isShown = false
    private(set) var isDisposed = false
    private(set) var events: [String] = []

    init(windowNumber: Int) { self.windowNumber = windowNumber }

    func place(_ frame: CGRect, ring: BorderRing, level: Int) {
        self.frame = frame
        self.ring = ring
        self.level = level
    }

    func setRole(_ role: BorderRole, animated: Bool) {
        self.role = role
        events.append("role \(role) animated: \(animated)")
    }

    private(set) var shownNextTo: (nativeWindowId: UInt32, above: Bool)? = nil
    var shownBelow: UInt32? { shownNextTo.flatMap { $0.above ? nil : $0.nativeWindowId } }
    var shownAbove: UInt32? { shownNextTo.flatMap { $0.above ? $0.nativeWindowId : nil } }

    func show(nextTo target: (nativeWindowId: UInt32, above: Bool)?) {
        isShown = true
        shownNextTo = target
    }

    /// The windows this border was ordered next to after it was shown, as "<window id> above|below"
    private(set) var reorders: [String] = []

    func reorder(nextTo target: (nativeWindowId: UInt32, above: Bool)) {
        reorders.append("\(target.nativeWindowId) \(target.above ? "above" : "below")")
    }
    func hide() { isShown = false }
    func dispose() { isDisposed = true }
}
