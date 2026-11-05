@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct TilingResizeTest {
    init() { setUpWorkspacesForTests() }

    @Test func testResizeRightEdge() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root).apply { $0.laidOut(x: 0, y: 0, width: 500, height: 1000) }
        let window2 = TestWindow.new(id: 2, parent: root).apply { $0.laidOut(x: 500, y: 0, width: 500, height: 1000) }

        applyTilingResize(window1, from: window1.physicalRect, to: Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 1000))
        assertEquals(window1.hWeight, 600)
        assertEquals(window2.hWeight, 400)
    }

    @Test func testSmallDiffIsIgnored() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root, adaptiveWeight: 7).apply { $0.laidOut(x: 0, y: 0, width: 500, height: 1000) }
        let window2 = TestWindow.new(id: 2, parent: root, adaptiveWeight: 7).apply { $0.laidOut(x: 500, y: 0, width: 500, height: 1000) }

        applyTilingResize(window1, from: window1.physicalRect, to: Rect(topLeftX: 0, topLeftY: 0, width: 503, height: 1000))
        assertEquals(window1.hWeight, 7)
        assertEquals(window2.hWeight, 7)
    }

    @Test func testWeightsAreClampedToMinimum() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root).apply { $0.laidOut(x: 0, y: 0, width: 500, height: 1000) }
        let window2 = TestWindow.new(id: 2, parent: root).apply { $0.laidOut(x: 500, y: 0, width: 500, height: 1000) }

        applyTilingResize(window1, from: window1.physicalRect, to: Rect(topLeftX: 0, topLeftY: 0, width: 1200, height: 1000))
        assertEquals(window1.hWeight, 1000 - minTilingResizeWeight)
        assertEquals(window2.hWeight, minTilingResizeWeight)

        applyTilingResize(window1, from: window1.physicalRect, to: Rect(topLeftX: 0, topLeftY: 0, width: 10, height: 1000))
        assertEquals(window1.hWeight, minTilingResizeWeight)
        assertEquals(window2.hWeight, 1000 - minTilingResizeWeight)
    }

    @Test func testNestedContainers() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root).apply { $0.laidOut(x: 0, y: 0, width: 500, height: 1000) }
        var window2: TestWindow!
        var window3: TestWindow!
        let column = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).apply {
            $0.lastAppliedLayoutVirtualRect = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000)
            window2 = TestWindow.new(id: 2, parent: $0).apply { $0.laidOut(x: 500, y: 0, width: 500, height: 500) }
            window3 = TestWindow.new(id: 3, parent: $0).apply { $0.laidOut(x: 500, y: 500, width: 500, height: 500) }
        }

        // Drag the top left corner of the window2: its left edge and its bottom edge stay, the top can't move
        applyTilingResize(window2, from: window2.physicalRect, to: Rect(topLeftX: 400, topLeftY: 0, width: 600, height: 600))
        assertEquals(column.hWeight, 600)
        assertEquals(window1.hWeight, 400)
        assertEquals(window2.vWeight, 600)
        assertEquals(window3.vWeight, 400)
    }

    @Test func testAccordionIsSkipped() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root).apply { $0.laidOut(x: 0, y: 0, width: 500, height: 1000) }
        var window2: TestWindow!
        let accordion = TilingContainer(parent: root, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST).apply {
            $0.lastAppliedLayoutVirtualRect = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000)
            window2 = TestWindow.new(id: 2, parent: $0).apply { $0.laidOut(x: 500, y: 0, width: 500, height: 1000) }
            TestWindow.new(id: 3, parent: $0).apply { $0.laidOut(x: 500, y: 0, width: 500, height: 1000) }
        }

        applyTilingResize(window2, from: window2.physicalRect, to: Rect(topLeftX: 300, topLeftY: 0, width: 700, height: 1000))
        assertEquals(accordion.hWeight, 700)
        assertEquals(window1.hWeight, 300)
    }
}

extension TestWindow {
    fileprivate func laidOut(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let rect = Rect(topLeftX: x, topLeftY: y, width: width, height: height)
        lastAppliedLayoutPhysicalRect = rect
        lastAppliedLayoutVirtualRect = rect
    }

    fileprivate var physicalRect: Rect { lastAppliedLayoutPhysicalRect.orDie() }
}
