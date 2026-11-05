import AppKit
import Common

let borderWidthRange: ClosedRange<Double> = 1 ... 50
let borderRadiusRange: ClosedRange<Double> = 0 ... 100
let borderGradientAngleRange: ClosedRange<Int> = -360 ... 360
let borderFocusSweepMsRange: ClosedRange<Int> = 0 ... 5000
/// Below the lower bound, the rotation is a flicker rather than a motion
let borderAngleAnimationPeriodMsRange: ClosedRange<Int> = 250 ... 600_000
let borderGlowRadiusRange: ClosedRange<Double> = 0 ... 50
let borderGlowOpacityRange: ClosedRange<Double> = 0 ... 1
let borderFocusPulseMsRange: ClosedRange<Int> = 0 ... 2000

struct BordersConfig: Withable, Equatable, Sendable {
    var enabled: Bool = false
    var width: Double = 5
    var radius: BorderRadius = .auto
    /// Where each border sits in the z-order relative to its window. Only with SkyLight: the public API fallback
    /// can't order a window relative to the windows of another app
    var order: BorderOrder = .below
    var activeColor = BorderPaint(ArgbColor(argb: 0xFFB5_37F2))
    /// nil: inactive windows get no border at all
    var inactiveColor: BorderPaint? = BorderPaint(ArgbColor(argb: 0xFF45_475A))
    /// 0 paints the gradient from left to right, 90 from top to bottom
    var gradientAngle: Int = 45
    var transitionMs: Int = 120
    var focusSweepMs: Int = 0
    /// 0 disables the continuous rotation of the active gradient
    var angleAnimationPeriodMs: Int = 0
    /// The blur radius of the glow around the active border. 0 disables the glow
    var glowRadius: Double = 0
    var glowOpacity: Double = 0.6
    /// nil: the glow takes the color of the active border
    var glowColor: ArgbColor? = nil
    /// 0 disables the pulse of the glow when a window gains focus
    var focusPulseMs: Int = 0
}

enum BorderOrder: String, Equatable, Sendable {
    /// Right below the window: only the outer half of the stroke shows, the border never covers the window
    case below
    /// Right above the window: the whole stroke shows, its inner half covers the edge of the window
    case above
}

enum BorderRadius: Equatable, Sendable {
    /// The corner radius of each window, as the WindowServer tells it
    case auto
    /// The same radius for every window
    case fixed(Double)
}

/// One color paints a solid border, two or more paint a gradient
struct BorderPaint: Equatable, Sendable {
    let colors: [ArgbColor]

    init(_ color: ArgbColor) { self.colors = [color] }

    init?(colors: [ArgbColor]) {
        if colors.isEmpty { return nil }
        self.colors = colors
    }

    var isGradient: Bool { colors.count > 1 }
}

private let bordersParser: [String: any ParserProtocol<BordersConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "width": Parser(\.width) { raw, backtrace in parseDouble(raw, backtrace, key: "width", borderWidthRange) },
    "radius": Parser(\.radius, parseBorderRadius),
    "order": Parser(\.order) { raw, backtrace in
        parseString(raw, backtrace).flatMap {
            BorderOrder(rawValue: $0).toResult(.init(backtrace, "Can't parse border order '\($0)'. Possible values: below, above"))
        }
    },
    "active-color": Parser(\.activeColor) { raw, backtrace in
        parseBorderPaint(raw, backtrace).flatMap { $0.toResult(.init(backtrace, "active-color can't be empty")) }
    },
    "inactive-color": Parser(\.inactiveColor, parseBorderPaint),
    "gradient-angle": Parser(\.gradientAngle) { raw, backtrace in parseIntInRange(raw, backtrace, key: "gradient-angle", borderGradientAngleRange) },
    "transition-ms": Parser(\.transitionMs) { raw, backtrace in parseAnimationDurationMs(raw, backtrace, key: "transition-ms") },
    "focus-sweep-ms": Parser(\.focusSweepMs) { raw, backtrace in parseIntInRange(raw, backtrace, key: "focus-sweep-ms", borderFocusSweepMsRange) },
    "angle-animation-period-ms": Parser(\.angleAnimationPeriodMs) { raw, backtrace in
        let range = borderAngleAnimationPeriodMsRange
        return parseInt(raw, backtrace).filter(.init(
            backtrace,
            "angle-animation-period-ms must be 0 (disabled) or in [\(range.lowerBound), \(range.upperBound)] range",
        )) { $0 == 0 || range.contains($0) }
    },
    "glow-radius": Parser(\.glowRadius) { raw, backtrace in parseDouble(raw, backtrace, key: "glow-radius", borderGlowRadiusRange) },
    "glow-opacity": Parser(\.glowOpacity) { raw, backtrace in parseDouble(raw, backtrace, key: "glow-opacity", borderGlowOpacityRange) },
    "glow-color": Parser(\.glowColor, parseOptionalArgbColor),
    "focus-pulse-ms": Parser(\.focusPulseMs) { raw, backtrace in parseIntInRange(raw, backtrace, key: "focus-pulse-ms", borderFocusPulseMsRange) },
]

func parseBorders(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> BordersConfig {
    let borders = parseNonEmptyTable(raw, BordersConfig(), bordersParser, backtrace, &c)
    // Only a gradient has an angle to turn
    if !borders.activeColor.isGradient {
        for (key, value) in [("focus-sweep-ms", borders.focusSweepMs), ("angle-animation-period-ms", borders.angleAnimationPeriodMs)] where value != 0 {
            c.warnings.append(.init(backtrace + .key(key), "Has no effect: active-color is a solid color, not a gradient"))
        }
    }
    // The pulse animates the glow, there is nothing to pulse without it
    if borders.focusPulseMs != 0 && borders.glowRadius == 0 {
        c.warnings.append(.init(backtrace + .key("focus-pulse-ms"), "Has no effect: glow-radius is 0, the glow is disabled"))
    }
    return borders
}

/// An empty string means no color
private func parseOptionalArgbColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<ArgbColor?> {
    if case .string("") = raw { return .success(nil) }
    return parseArgbColor(raw, backtrace).map(Optional.some)
}

/// A string or an integer is a solid color, an array is a gradient. An empty string means no color
private func parseBorderPaint(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<BorderPaint?> {
    switch raw {
        case .string(""):
            return .success(nil)
        case .array(let array):
            return array.enumerated()
                .mapAllOrFailure { index, elem in parseArgbColor(elem, backtrace + .index(index)) }
                .flatMap { BorderPaint(colors: $0).toResult(.init(backtrace, "A gradient needs at least one color")) }
                .map(Optional.some)
        default:
            return parseArgbColor(raw, backtrace).map { BorderPaint($0) }
    }
}

private func parseBorderRadius(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<BorderRadius> {
    let range = borderRadiusRange
    let message = "radius must be 'auto' or in [\(Int(range.lowerBound)), \(Int(range.upperBound))] range"
    if case .string(let string) = raw {
        return string == "auto" ? .success(.auto) : .failure(.init(backtrace, message))
    }
    return raw.asDoubleOrNil.toResult(expectedActualTypeDiagnostic(expected: [.string, .int, .float], actual: raw.tomlType, backtrace))
        .filter(.init(backtrace, message)) { range.contains($0) }
        .map(BorderRadius.fixed)
}

private func parseDouble(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, key: String, _ range: ClosedRange<Double>) -> ResOrConfigParseDiagnostic<Double> {
    raw.asDoubleOrNil.toResult(expectedActualTypeDiagnostic(expected: [.int, .float], actual: raw.tomlType, backtrace))
        .filter(.init(backtrace, "\(key) must be in [\(Int(range.lowerBound)), \(Int(range.upperBound))] range")) { range.contains($0) }
}

private func parseIntInRange(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, key: String, _ range: ClosedRange<Int>) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace)
        .filter(.init(backtrace, "\(key) must be in [\(range.lowerBound), \(range.upperBound)] range")) { range.contains($0) }
}
