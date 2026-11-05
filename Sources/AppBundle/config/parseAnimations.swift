import AppKit
import Common

let animationDurationMsRange: ClosedRange<Int> = 0 ... 1000
let animationsMaxWindowsRange: ClosedRange<Int> = 1 ... 100

struct AnimationsConfig: Withable, Equatable, Sendable {
    /// Above this many planned moves in one layout pass, all of them jump.
    /// Every frame of every animated window is an AX request to its app
    var maxWindows: Int = 12
    /// Curves defined by the user, by name. Built-in curves aren't here, see ``AnimationCurve/builtIns``
    var beziers: [String: CubicBezier] = [:]
    var windowsMove = AnimationConfig(enabled: false, durationMs: 150, curve: .easeOut)
    /// Still requires `[mouse-grab] live-preview`
    var mouseGrab = AnimationConfig(enabled: true, durationMs: 150, curve: .easeOut)
    var scratchpad = AnimationConfig(enabled: false, durationMs: 200, curve: .easeOut)
}

struct AnimationConfig: Withable, Equatable, Sendable {
    var enabled: Bool
    var durationMs: Int
    var curve: AnimationCurve
    /// Only configurable in `[animations.windows-move]`. False animates the position only and applies the size at the
    /// end, for apps that are slow to resize
    var animateSize: Bool = true
    /// Only configurable in `[animations.scratchpad]`
    var direction: ScratchpadSlideDirection = .bottom

    var isEnabled: Bool { enabled && durationMs > 0 }

    var style: FrameAnimationStyle {
        FrameAnimationStyle(duration: .milliseconds(durationMs), easing: curve.easing, animatesSize: animateSize)
    }
}

/// The side of the monitor the scratchpad slides from and to.
/// There is no `top`: macOS keeps title bars below the menu bar, so a window can't reliably leave through the top
enum ScratchpadSlideDirection: String, CaseIterable, Sendable {
    case bottom, left, right
}

private let bezierKey = "bezier"

func parseAnimations(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> AnimationsConfig {
    // The curves of the other tables refer to the beziers by name, whatever the order of the keys is
    let beziers = raw.asDictOrNil?[bezierKey].map { parseBeziers($0, backtrace + .key(bezierKey), &c) } ?? [:]
    let curves = AnimationCurve.builtIns.merging(beziers.map { ($0, AnimationCurve(name: $0, easing: .bezier($1))) }) { builtIn, _ in builtIn }
    let common: [String: any ParserProtocol<AnimationConfig>] = [
        "enabled": Parser(\.enabled, parseBool),
        "duration-ms": Parser(\.durationMs) { raw, backtrace in parseAnimationDurationMs(raw, backtrace, key: "duration-ms") },
        "curve": Parser(\.curve) { raw, backtrace in parseAnimationCurve(raw, backtrace, curves) },
    ]
    let windowsMoveParsers = common.merging(["animate-size": Parser(\.animateSize, parseBool)]) { _, new in new }
    let scratchpadParsers = common.merging(["direction": Parser(\.direction, parseScratchpadSlideDirection)]) { _, new in new }
    let parsers: [String: any ParserProtocol<AnimationsConfig>] = [
        bezierKey: Parser(\.beziers) { _, _ in .success(beziers) }, // Parsed above
        "max-windows": Parser(\.maxWindows, parseAnimationsMaxWindows),
        "windows-move": Parser(\.windowsMove) { raw, backtrace, c in
            parseNonEmptyTable(raw, AnimationsConfig().windowsMove, windowsMoveParsers, backtrace, &c)
        },
        "mouse-grab": Parser(\.mouseGrab) { raw, backtrace, c in
            parseNonEmptyTable(raw, AnimationsConfig().mouseGrab, common, backtrace, &c)
        },
        "scratchpad": Parser(\.scratchpad) { raw, backtrace, c in
            parseNonEmptyTable(raw, AnimationsConfig().scratchpad, scratchpadParsers, backtrace, &c)
        },
    ]
    return parseNonEmptyTable(raw, AnimationsConfig(), parsers, backtrace, &c)
}

/// `[mouse-grab] animation-duration-ms` is the deprecated spelling of `[animations.mouse-grab] duration-ms`
func applyDeprecatedMouseGrabAnimationDuration(_ config: inout Config, _ rawTable: OrderedJson.JsonDict, _ c: inout ConfigParserContext) {
    guard let durationMs = config.mouseGrab._animationDurationMs else { return }
    let backtrace: ConfigBacktrace = .rootKey("mouse-grab") + .key(deprecatedMouseGrabAnimationDurationKey)
    let isNewKeySet = rawTable["animations"]?.asDictOrNil?["mouse-grab"]?.asDictOrNil?["duration-ms"] != nil
    if isNewKeySet {
        c.errors.append(.init(backtrace, "Conflicts with animations.mouse-grab.duration-ms. Please drop the deprecated key"))
    } else {
        c.warnings.append(.init(backtrace, "Deprecated. Please use animations.mouse-grab.duration-ms instead"))
        config.animations.mouseGrab.durationMs = durationMs
    }
}

func parseAnimationDurationMs(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, key: String) -> ResOrConfigParseDiagnostic<Int> {
    let range = animationDurationMsRange
    return parseInt(raw, backtrace)
        .filter(.init(backtrace, "\(key) must be in [\(range.lowerBound), \(range.upperBound)] range")) { range.contains($0) }
}

private func parseAnimationsMaxWindows(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    let range = animationsMaxWindowsRange
    return parseInt(raw, backtrace)
        .filter(.init(backtrace, "max-windows must be in [\(range.lowerBound), \(range.upperBound)] range")) { range.contains($0) }
}

private func parseAnimationCurve(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ curves: [String: AnimationCurve]) -> ResOrConfigParseDiagnostic<AnimationCurve> {
    parseString(raw, backtrace).flatMap { name in
        curves[name].toResult(.init(
            backtrace,
            "Unknown curve '\(name)'. Possible values: \(curves.keys.sorted().joined(separator: ", ")). " +
                "Custom curves are defined in [animations.bezier]",
        ))
    }
}

private func parseScratchpadSlideDirection(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<ScratchpadSlideDirection> {
    parseString(raw, backtrace).flatMap {
        ScratchpadSlideDirection(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse direction '\($0)'. Possible values: \(ScratchpadSlideDirection.cliArgsCases.joined(separator: ", "))"))
    }
}

private func parseBeziers(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: CubicBezier] {
    guard let table = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: CubicBezier] = [:]
    for (name, value) in table {
        let backtrace = backtrace + .key(name)
        if AnimationCurve.builtIns[name] != nil {
            c.errors.append(.init(backtrace, "'\(name)' is a built-in curve and can't be redefined"))
            continue
        }
        if let bezier = parseBezier(value, backtrace).getOrNil(appendErrorTo: &c.errors) {
            result[name] = bezier
        }
    }
    return result
}

private func parseBezier(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<CubicBezier> {
    let format = "A bezier is an array of 4 numbers: [x1, y1, x2, y2]"
    guard let array = raw.asArrayOrNil, array.count == 4 else { return .failure(.init(backtrace, format)) }
    let points = array.compactMap(\.asDoubleOrNil)
    guard points.count == 4 else { return .failure(.init(backtrace, format)) }
    guard (0 ... 1).contains(points[0]) && (0 ... 1).contains(points[2]) else {
        return .failure(.init(backtrace, "x1 and x2 must be in [0, 1] range. They are the time of the control points"))
    }
    return .success(CubicBezier(points[0], points[1], points[2], points[3]))
}
