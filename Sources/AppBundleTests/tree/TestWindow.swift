@testable import AppBundle
import AppKit
import Common

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?
    var isMacosFullscreenForTest = false
    private(set) var setAxFrameCalls: [(topLeft: CGPoint?, size: CGSize?)] = []

    @MainActor
    private init(_ id: OpaqueWindowId, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?, _ index: Int) {
        _rect = rect
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @discardableResult
    @MainActor
    static func new(id: OpaqueWindowId, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil, index: Int = INDEX_BIND_LAST) -> TestWindow {
        let wi = TestWindow(id, parent, adaptiveWeight, rect, index)
        TestApp.shared._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    /// nil reports the description as the title
    var titleForTest: String? = nil
    override func getTitle(_ cm: CancellationMode) async throws -> String { titleForTest ?? description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        _rect
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        _rect.map { CGSize(width: $0.width, height: $0.height) }
    }

    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { isMacosFullscreenForTest }

    override func setNativeAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        setAxFrameCalls.append((topLeft, size))
        let prev = _rect ?? Rect(topLeftX: 0, topLeftY: 0, width: 0, height: 0)
        _rect = Rect(
            topLeftX: topLeft?.x ?? prev.topLeftX,
            topLeftY: topLeft?.y ?? prev.topLeftY,
            width: size?.width ?? prev.width,
            height: size?.height ?? prev.height,
        )
    }

    /// Test windows are never hidden in the corner. Only records what the real window would restore on unhide
    private(set) var frameToUnhide: Rect?
    @MainActor override func forgetHiddenInCornerPosition() { frameToUnhide = nil }
    @MainActor override func rememberFrameToUnhide(_ rect: Rect, monitorRect: Rect) { frameToUnhide = rect }
}

extension OpaqueWindowId: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) { self.init(value) }
}
