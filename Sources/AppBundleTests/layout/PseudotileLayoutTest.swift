@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct PseudotileLayoutTest {
    init() { setUpWorkspacesForTests() }

    @Test func testPseudoTiledRect() {
        let slot = rect(100, 200, 1000, 800)
        assertEquals(pseudoTiledRect(CGSize(width: 600, height: 400), in: slot), rect(300, 400, 600, 400))
        // Too wide: scaled down to the width of the slot, keeping the aspect ratio
        assertEquals(pseudoTiledRect(CGSize(width: 2000, height: 1000), in: slot), rect(100, 350, 1000, 500))
        // Too high
        assertEquals(pseudoTiledRect(CGSize(width: 400, height: 1600), in: slot), rect(500, 200, 200, 800))
        assertEquals(pseudoTiledRect(CGSize(width: 1000, height: 800), in: slot), slot)
    }

    @Test func testWindowIsCenteredInItsSlot() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        window1.isPseudoTiled = true
        window1.pseudoSize = CGSize(width: 800, height: 600)
        try await workspace.layoutWorkspace()

        assertEquals(window1.frames.last, rect(80, 239.5, 800, 600))
        assertEquals(window2.frames.last, rect(960, 0, 960, 1079))
        // The slot, not the frame: dwindle placement, the mouse grab and the drop hit-testing need it
        assertEquals(window1.lastAppliedLayoutPhysicalRect, rect(0, 0, 960, 1079))
    }

    @Test func testOversizedWindowIsScaledDown() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        window1.isPseudoTiled = true
        window1.pseudoSize = CGSize(width: 1200, height: 900)
        try await workspace.layoutWorkspace()

        assertEquals(window1.frames.last, rect(0, 179.5, 960, 720))
        assertEquals(window1.pseudoSize, CGSize(width: 1200, height: 900)) // Scaling doesn't forget the size
    }

    @Test func testOffIsUnchangedBehaviour() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.pseudoSize = CGSize(width: 800, height: 600)
        try await workspace.layoutWorkspace()
        assertEquals(window.frames.last, rect(0, 0, 1920, 1079))
    }

    @Test func testFullscreenTakesPrecedence() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.isPseudoTiled = true
        window.pseudoSize = CGSize(width: 800, height: 600)
        window.isFullscreen = true
        try await workspace.layoutWorkspace()
        assertEquals(window.frames.last, rect(0, 0, 1920, 1080))
    }

    @Test func testAccordionPaddingShrinksTheSlotFirst() async throws {
        config.accordionPadding = 30
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        workspace.rootTilingContainer.layout = .accordion
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        window1.isPseudoTiled = true
        window1.pseudoSize = CGSize(width: 3780, height: 1890)
        try await workspace.layoutWorkspace()
        // The slot of window1 is 1890 wide, so the size is scaled down
        assertEquals(window1.lastAppliedLayoutPhysicalRect, rect(0, 0, 1890, 1079))
        assertEquals(window1.frames.last, rect(0, 67, 1890, 945))
    }

    @Test func testKeyboardResizeChangesTheSlot() async throws {
        let workspace = Workspace.get(byName: name)
        check(workspace.focusWorkspace())
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        window1.isPseudoTiled = true
        window1.pseudoSize = CGSize(width: 800, height: 600)
        assertEquals(window1.focusWindow(), true)
        try await workspace.layoutWorkspace()

        assertEquals(await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 0)
        try await workspace.layoutWorkspace()
        assertEquals(window1.lastAppliedLayoutPhysicalRect, rect(0, 0, 1060, 1079))
        assertEquals(window1.frames.last, rect(130, 239.5, 800, 600))
        assertEquals(window1.pseudoSize, CGSize(width: 800, height: 600))
    }

    @Test func testMouseResizeChangesThePseudoSize() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        let slot = rect(0, 0, 500, 1000)
        window1.lastAppliedLayoutPhysicalRect = slot
        window1.lastAppliedLayoutVirtualRect = slot
        window1.isPseudoTiled = true
        window1.pseudoSize = CGSize(width: 300, height: 400)

        applyTilingWindowResize(window1, from: slot, to: rect(100, 300, 350, 450))
        assertEquals(window1.pseudoSize, CGSize(width: 350, height: 450))
        assertEquals(window1.hWeight, 1)
        assertEquals(window2.hWeight, 1)
    }

    @Test func testMouseResizeOfATiledWindowChangesTheWeights() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window2 = TestWindow.new(id: 2, parent: root)
        for (window, x) in [(window1, 0.0), (window2, 500.0)] {
            window.lastAppliedLayoutPhysicalRect = rect(x, 0, 500, 1000)
            window.lastAppliedLayoutVirtualRect = rect(x, 0, 500, 1000)
        }

        applyTilingWindowResize(window1, from: rect(0, 0, 500, 1000), to: rect(0, 0, 600, 1000))
        assertEquals(window1.hWeight, 600)
        assertEquals(window2.hWeight, 400)
        assertNil(window1.pseudoSize)
    }

    @Test func testFrozenRoundTrip() {
        let workspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        window1.isPseudoTiled = true
        window1.pseudoSize = CGSize(width: 800, height: 600)
        let frozen = FrozenTilingTree(workspace)
        guard case .window(let frozenWindow1) = frozen.root.children.first else { Issue.record("Not a window"); return }
        assertEquals(frozenWindow1.isPseudoTiled, true)
        assertEquals(frozenWindow1.pseudoSize, CGSize(width: 800, height: 600))

        window1.isPseudoTiled = false
        window1.pseudoSize = nil
        restoreTilingTrees([frozen])
        assertEquals(window1.isPseudoTiled, true)
        assertEquals(window1.pseudoSize, CGSize(width: 800, height: 600))
        assertEquals(FrozenContainer(workspace.rootTilingContainer), frozen.root)
    }
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Rect {
    Rect(topLeftX: x, topLeftY: y, width: width, height: height)
}
