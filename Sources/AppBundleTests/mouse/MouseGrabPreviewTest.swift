@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct MouseGrabPreviewTest {
    init() {
        setUpWorkspacesForTests()
        config.mouseGrab.livePreview = true
    }

    @Test func testMovePreviewSwapsAndCancelRestores() async throws {
        let (workspace, windows) = try await setUpVisibleWorkspace(windowCount: 3)
        let window1 = windows[0]
        let frozenBefore = FrozenContainer(workspace.rootTilingContainer)
        currentlyManipulatedWithMouseWindowId = window1.windowId
        defer { currentlyManipulatedWithMouseWindowId = nil }
        var steps = 0
        let preview = MouseGrabPreview(
            window1,
            .move,
            startRect: window1.lastAppliedLayoutPhysicalRect.orDie(),
            mouse: CGPoint(x: 320, y: 500),
            after: nil,
            runMoveStep: { step in
                steps += 1
                let didChange = step()
                try await workspace.layoutWorkspace(animation: .mouseGrab)
                return didChange
            },
        )
        assertNil(window1.lastAppliedLayoutPhysicalRect)

        preview.update(mouse: CGPoint(x: 1600, y: 500), rect: anyRect)
        await preview.settle()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))
        assertEquals(steps, 1)
        // The neighbour animates into the slot that the dragged window left. The dragged window stays where the mouse is
        assertEquals(frameAnimator.target(of: windows[2]), Rect(topLeftX: 0, topLeftY: 0, width: 640, height: 1079))
        assertNil(frameAnimator.target(of: window1))
        assertEquals(window1.setAxFrameCalls.count, 1)

        // The mouse is over the new slot of the dragged window: nothing to do, and no swapping back
        preview.update(mouse: CGPoint(x: 1610, y: 500), rect: anyRect)
        await preview.settle()
        assertEquals(steps, 1)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))

        preview.update(mouse: CGPoint(x: 960, y: 500), rect: anyRect)
        await preview.settle()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(1), .window(2)]))

        await preview.stop()
        preview.restore()
        assertEquals(FrozenContainer(workspace.rootTilingContainer), frozenBefore)
    }

    @Test func testMovePreviewOverOwnSlotIsNoop() async throws {
        let (workspace, windows) = try await setUpVisibleWorkspace(windowCount: 2)
        let window1 = windows[0]
        var steps = 0
        let preview = MouseGrabPreview(
            window1,
            .move,
            startRect: window1.lastAppliedLayoutPhysicalRect.orDie(),
            mouse: CGPoint(x: 320, y: 500),
            after: nil,
            runMoveStep: { step in
                steps += 1
                return step()
            },
        )
        preview.update(mouse: CGPoint(x: 400, y: 500), rect: anyRect)
        await preview.settle()
        assertEquals(steps, 0)
        assertEquals(preview.frozenTrees.count, 0)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    @Test func testResizePreviewAppliesWeightsAndCancelRestores() async throws {
        let (workspace, windows) = try await setUpVisibleWorkspace(windowCount: 2)
        let (window1, window2) = (windows[0], windows[1])
        let frozenBefore = FrozenContainer(workspace.rootTilingContainer)
        currentlyManipulatedWithMouseWindowId = window1.windowId
        defer { currentlyManipulatedWithMouseWindowId = nil }
        let startRect = window1.lastAppliedLayoutPhysicalRect.orDie()
        let preview = MouseGrabPreview(window1, .resize, startRect: startRect, mouse: CGPoint(x: 950, y: 500), after: nil)

        preview.update(mouse: CGPoint(x: 1190, y: 500), rect: startRect.with(\.width, 1200))
        await preview.settle()
        assertEquals(window1.hWeight, 1200)
        assertEquals(window2.hWeight, 720)
        assertEquals(window2.frames.last, Rect(topLeftX: 1200, topLeftY: 0, width: 720, height: 1079))
        assertEquals(window1.setAxFrameCalls.count, 1) // The grab moves the grabbed window itself

        // The baseline is frozen for the whole gesture: the diff is against the start, not the previous step
        preview.update(mouse: CGPoint(x: 1090, y: 500), rect: startRect.with(\.width, 1100))
        await preview.settle()
        assertEquals(window1.hWeight, 1100)
        assertEquals(window2.hWeight, 820)

        await preview.stop()
        preview.restore()
        assertEquals(FrozenContainer(workspace.rootTilingContainer), frozenBefore)
        assertEquals(window1.hWeight, 960)
        assertEquals(window2.hWeight, 960)
    }

    private func setUpVisibleWorkspace(windowCount: Int) async throws -> (Workspace, [TestWindow]) {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let windows = (1 ... windowCount).map { TestWindow.new(id: OpaqueWindowId(UInt64($0)), parent: workspace.rootTilingContainer) }
        try await workspace.layoutWorkspace()
        return (workspace, windows)
    }
}

private let anyRect = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)
