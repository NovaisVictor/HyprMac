import Foundation

extension CGRect {
    var withYAxisFlipped: Rect {
        let mainMonitorHeight: CGFloat = mainMonitorInfo.height
        let rect = toRect()
        return rect.with(\.topLeftY, mainMonitorHeight - rect.topLeftY)
    }
}

extension CGPoint {
    var withYAxisFlipped: CGPoint {
        consuming get {
            self.y = mainMonitorInfo.height - self.y
            return self
        }
    }
}

extension Rect {
    /// The inverse of ``CGRect/withYAxisFlipped``: the frame for AppKit, whose origin is the bottom left corner of the
    /// main screen, with the y-axis going up
    var cocoaFrame: CGRect {
        CGRect(x: topLeftX, y: mainMonitorInfo.height - topLeftY - height, width: width, height: height)
    }
}
