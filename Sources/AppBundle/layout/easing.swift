import AppKit
import Common

/// Maps the time progress of an animation (from 0 to 1) to its motion progress
enum Easing: Equatable, Sendable {
    case linear
    case bezier(CubicBezier)

    func progress(_ time: CGFloat) -> CGFloat {
        let time = time.coerce(in: 0 ... 1)
        return switch self {
            case .linear: time
            case .bezier(let bezier): bezier.progress(time)
        }
    }
}

/// CSS-like cubic bezier from (0, 0) to (1, 1). The x of the control points is the time, so it must be in [0, 1].
/// The y may go outside [0, 1] to overshoot.
///
/// Solving the curve for x takes several iterations, too much for every frame of every animated window.
/// So the curve is solved once, when the config is parsed, into a lookup table
struct CubicBezier: Equatable, Sendable {
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double
    private let table: [CGFloat]

    static let tableSize = 256

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        check((0 ... 1).contains(x1) && (0 ... 1).contains(x2), "The x of bezier control points must be in [0, 1]")
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        let lastIndex = Self.tableSize - 1
        table = (0 ... lastIndex).map { index in
            let x = Double(index) / Double(lastIndex)
            return CGFloat(bezierCoordinate(solveBezierT(forX: x, x1, x2), y1, y2))
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.x1 == rhs.x1 && lhs.y1 == rhs.y1 && lhs.x2 == rhs.x2 && lhs.y2 == rhs.y2
    }

    fileprivate func progress(_ time: CGFloat) -> CGFloat {
        let position = time * CGFloat(table.count - 1)
        let index = min(Int(position), table.count - 2)
        let fraction = position - CGFloat(index)
        return table[index] + (table[index + 1] - table[index]) * fraction
    }
}

/// One coordinate of the bezier with the end points 0 and 1
private func bezierCoordinate(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
    let u = 1 - t
    return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
}

private func bezierDerivative(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
    let u = 1 - t
    return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
}

/// x(t) is monotonic because the x of both control points is in [0, 1]. Newton converges in a few steps on most
/// of the curve, but stalls where the derivative is close to zero. Bisection always converges there
private func solveBezierT(forX x: Double, _ x1: Double, _ x2: Double) -> Double {
    let epsilon = 1e-7
    var t = x
    for _ in 0 ..< 8 {
        let error = bezierCoordinate(t, x1, x2) - x
        if abs(error) < epsilon { return t }
        let derivative = bezierDerivative(t, x1, x2)
        if abs(derivative) < 1e-6 { break }
        t = min(max(t - error / derivative, 0), 1)
    }
    var low = 0.0
    var high = 1.0
    t = x
    for _ in 0 ..< 64 {
        let value = bezierCoordinate(t, x1, x2)
        if abs(value - x) < epsilon { return t }
        if value < x { low = t } else { high = t }
        t = (low + high) / 2
    }
    return t
}

/// A curve as the config names it
struct AnimationCurve: Equatable, Sendable {
    let name: String
    let easing: Easing

    static let linear = AnimationCurve(name: "linear", easing: .linear)
    /// Close to a cubic ease-out: the window starts fast and slows down as it lands
    static let easeOut = AnimationCurve(name: "ease-out", easing: .bezier(CubicBezier(0.33, 1, 0.68, 1)))
    static let easeInOut = AnimationCurve(name: "ease-in-out", easing: .bezier(CubicBezier(0.42, 0, 0.58, 1)))

    static let builtIns: [String: AnimationCurve] = Dictionary(uniqueKeysWithValues: [linear, easeOut, easeInOut].map { ($0.name, $0) })
}
