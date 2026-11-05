import AppKit
import Common

struct Rect: Withable, AeroAny, Equatable {
    var topLeftX: CGFloat
    var topLeftY: CGFloat

    private var _width: CGFloat
    var width: CGFloat {
        get { max(_width, 0) }
        set(newValue) { _width = newValue }
    }

    private var _height: CGFloat
    var height: CGFloat {
        get { max(_height, 0) }
        set(newValue) { _height = newValue }
    }

    init(topLeftX: CGFloat, topLeftY: CGFloat, width: CGFloat, height: CGFloat) {
        self.topLeftX = topLeftX
        self.topLeftY = topLeftY
        self._width = width
        self._height = height
    }
}

extension CGRect {
    func toRect() -> Rect {
        Rect(topLeftX: minX, topLeftY: maxY, width: width, height: height)
    }
}

extension Rect {
    func contains(_ point: CGPoint) -> Bool {
        minX.until(excl: maxX)?.contains(point.x) == true && minY.until(excl: maxY)?.contains(point.y) == true
    }

    var center: CGPoint {
        CGPoint(x: topLeftX + width / 2, y: topLeftY + height / 2)
    }

    /// A rect of the given size with the same center
    func centered(_ size: CGSize) -> Rect {
        Rect(topLeftX: topLeftX + (width - size.width) / 2, topLeftY: topLeftY + (height - size.height) / 2, width: size.width, height: size.height)
    }

    var topLeftCorner: CGPoint { CGPoint(x: topLeftX, y: topLeftY) }
    // periphery:ignore
    var topRightCorner: CGPoint { CGPoint(x: maxX, y: minY) }
    var bottomRightCorner: CGPoint { CGPoint(x: maxX, y: maxY) }
    var bottomLeftCorner: CGPoint { CGPoint(x: minX, y: maxY) }

    var minY: CGFloat { topLeftY }
    var maxY: CGFloat { topLeftY + height }
    var minX: CGFloat { topLeftX }
    var maxX: CGFloat { topLeftX + width }

    var size: CGSize { CGSize(width: width, height: height) }

    func getDimension(_ orientation: Orientation) -> CGFloat { orientation == .h ? width : height }

    /// Maps an absolute point to fractions of the rect's width and height, relative to its top-left corner
    func proportionalPoint(_ absolute: CGPoint) -> CGPoint {
        CGPoint(x: (absolute.x - topLeftX) / width, y: (absolute.y - topLeftY) / height)
    }

    /// The inverse of ``proportionalPoint(_:)``
    func absolutePoint(fromProportional proportional: CGPoint) -> CGPoint {
        CGPoint(x: topLeftX + width * proportional.x, y: topLeftY + height * proportional.y)
    }
}
