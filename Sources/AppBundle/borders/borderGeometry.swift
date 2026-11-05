import AppKit
import Common

// The border is a stroke along the edge of the window, like JankyBorders draws it. Its `width` is the width of the
// stroke, centered on the edge of the window:
// - Each border is ordered right below its window (``BorderPlacement/belowWindow``, `order = 'below'`). The inner
//   half of the stroke is hidden under the window, so a border looks `width / 2` thick. That hidden half also covers
//   the small differences between the curve of the border and the real corner of the window.
// - With `order = 'above'`, each border is ordered right above its window (``BorderPlacement/rightAboveWindow``).
//   The whole stroke shows, `width` thick, and its inner half covers the edge of the window. Other windows that
//   overlap the window still overlap its border.
// - The public API fallback floats the borders above the windows (``BorderPlacement/aboveWindow``). A centered stroke
//   would cover the content of the window, so only the outer half is drawn: a band of `width / 2` outside the frame,
//   whose inner edge is rounded with the radius of the window.
// In both cases, the visible band starts at the edge of the window and ends `width / 2` outside of it, with an outer
// radius of `windowRadius + width / 2`. Only the hidden inner half differs.
// A side effect: with inner gaps smaller than `width`, the borders of two neighbours overlap

enum BorderPlacement: Equatable {
    /// Each border is ordered right below its window, at the level of the window
    case belowWindow
    /// Each border is ordered right above its window, at the level of the window
    case rightAboveWindow
    /// The borders float above all the normal windows
    case aboveWindow
}

/// The stroke of a border window, as Core Animation draws it: a border of `lineWidth` inside the bounds of the layer,
/// whose outer edge is rounded with `cornerRadius`
struct BorderRing: Equatable {
    let lineWidth: CGFloat
    let cornerRadius: CGFloat
}

/// How far the visible ring reaches outside the frame of the window, on each side
func borderOutset(width: CGFloat) -> CGFloat { width / 2 }

/// The frame of the border window, in the top-left coordinates of AX and of the WindowServer. The window reaches
/// `glowMargin` further than the ring, so that the blur of the glow isn't cut by its edges
func borderFrame(around window: Rect, width: CGFloat, glowMargin: CGFloat) -> Rect {
    let outset = borderOutset(width: width) + glowMargin
    return Rect(topLeftX: window.topLeftX - outset, topLeftY: window.topLeftY - outset, width: window.width + 2 * outset, height: window.height + 2 * outset)
}

// The glow is the shadow of the outer edge of the ring, a filled rounded rect. Its blur spreads on both sides of that
// edge, and the inside of the shape is filled too. None of it may tint the window:
// - below the window (``BorderPlacement/belowWindow``), an opaque window hides it. A translucent one doesn't: a
//   terminal with a transparent background, or a vibrant sidebar, would show the glow through;
// - above the window (``BorderPlacement/aboveWindow``), it would cover the content.
// So in both placements the glow is clipped to the outside of the window. Between the edge of the window and the
// outer edge of the ring, the ring is drawn over the glow, so a difference between the curve of the clip and the
// real corner of the window doesn't show.

/// Where the layers of a border window go, in the coordinates of its root layer, whose bounds are the border window
struct BorderLayerFrames: Equatable {
    /// The ring, and the gradient that it masks
    let ring: CGRect
    /// The outer edge of the visible ring: the shape that casts the glow
    let glowShape: CGRect
    let glowShapeCornerRadius: CGFloat
    /// The glow is clipped by a layer border that covers the whole border window but the window itself. The inner
    /// edge of that border is the edge of the window, rounded with the radius of the window, like the inner edge of
    /// the ring in ``BorderPlacement/aboveWindow``
    let glowClipWidth: CGFloat
    let glowClipCornerRadius: CGFloat
}

func borderLayerFrames(size: CGSize, ring: BorderRing, width: CGFloat, glowMargin: CGFloat) -> BorderLayerFrames {
    let ringFrame = CGRect(origin: .zero, size: size).insetBy(dx: glowMargin, dy: glowMargin)
    return BorderLayerFrames(
        ring: ringFrame,
        glowShape: ringFrame,
        // CGPath requires a radius that fits the rect. Core Animation clamps the radius of layers by itself
        glowShapeCornerRadius: max(0, min(ring.cornerRadius, ringFrame.width / 2, ringFrame.height / 2)),
        glowClipWidth: glowMargin + borderOutset(width: width),
        glowClipCornerRadius: ring.cornerRadius + glowMargin,
    )
}

func borderRing(windowRadius: CGFloat, width: CGFloat, placement: BorderPlacement) -> BorderRing {
    let outset = borderOutset(width: width)
    return switch placement {
        case .belowWindow, .rightAboveWindow: BorderRing(lineWidth: width, cornerRadius: windowRadius + outset)
        case .aboveWindow: BorderRing(lineWidth: outset, cornerRadius: windowRadius + outset)
    }
}

/// AppKit places windows in bottom-left coordinates, whose origin is the bottom-left corner of the main monitor
func cocoaFrame(_ rect: Rect, mainMonitorHeight: CGFloat) -> CGRect {
    CGRect(x: rect.topLeftX, y: mainMonitorHeight - rect.maxY, width: rect.width, height: rect.height)
}

/// The rotation of the gradient layer for a `gradient-angle`. The angle turns clockwise on the screen
/// (0 is left to right, 90 is top to bottom), but the layers of AppKit views have their y axis going up,
/// where a positive rotation is counterclockwise
func gradientRotation(degrees: Int) -> CGFloat { -CGFloat(degrees) * .pi / 180 }

/// The gradient layer is a square as large as the diagonal of the border, so that it covers the border at any angle
/// while it rotates. Only a band of it is visible: the projection of the border on the direction of the gradient.
/// The color stops are spread over that band, so the first and the last colors are reached at the edges of the border
func gradientLocations(count: Int, size: CGSize, degrees: Int) -> [CGFloat] {
    if count < 2 { return [0.5] }
    let angle = CGFloat(degrees) * .pi / 180
    let diagonal = hypot(size.width, size.height)
    guard diagonal > 0 else { return (0 ..< count).map { CGFloat($0) / CGFloat(count - 1) } }
    let visible = (size.width * abs(cos(angle)) + size.height * abs(sin(angle))) / diagonal
    let start = (1 - visible) / 2
    return (0 ..< count).map { start + visible * CGFloat($0) / CGFloat(count - 1) }
}

/// Premultiplication isn't needed: the components are interpolated the same way Core Animation interpolates colors
struct RgbaComponents: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: ArgbColor) { self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha) }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// Core Animation can only animate between two gradients with the same number of colors. A gradient is
/// resampled to `count` evenly spaced stops; a solid color becomes `count` copies of itself
func resampledColors(_ colors: [ArgbColor], count: Int) -> [RgbaComponents] {
    let components = colors.map(RgbaComponents.init)
    guard components.count > 1, count > 1 else { return Array(repeating: components.first.orDie(), count: max(count, 1)) }
    return (0 ..< count).map { index in
        let position = CGFloat(index) / CGFloat(count - 1) * CGFloat(components.count - 1)
        let lower = min(max(Int(position.rounded(.down)), 0), components.count - 1)
        let upper = min(lower + 1, components.count - 1)
        let fraction = position - CGFloat(lower)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * fraction }
        let a = components[lower]
        let b = components[upper]
        return RgbaComponents(red: lerp(a.red, b.red), green: lerp(a.green, b.green), blue: lerp(a.blue, b.blue), alpha: lerp(a.alpha, b.alpha))
    }
}

// The glow is the shadow of the active ring. Core Animation's `shadowRadius` acts as the standard deviation of a
// Gaussian blur (it matches a CSS blur of twice the radius), so the glow fades out over a few `shadowRadius`

/// The shadow of the glow layer of a border window
struct BorderGlowStyle: Equatable {
    let color: RgbaComponents
    let radius: CGFloat
    /// 0 for the inactive borders: Core Animation skips a fully transparent shadow
    let opacity: CGFloat
}

/// nil when the glow is disabled: the border windows have no glow layer at all
func borderGlowStyle(_ config: BordersConfig, role: BorderRole) -> BorderGlowStyle? {
    guard config.glowRadius > 0 else { return nil }
    let opacity = switch role {
        case .active: CGFloat(config.glowOpacity)
        case .inactive: CGFloat(0)
    }
    // The color stays the same for both roles, so that a focus change only fades the glow in or out
    return BorderGlowStyle(color: borderGlowColor(config), radius: CGFloat(config.glowRadius), opacity: opacity)
}

/// `glow-color`, or the color of the active border. A gradient glows with the color at its middle
func borderGlowColor(_ config: BordersConfig) -> RgbaComponents {
    if let glowColor = config.glowColor { return RgbaComponents(glowColor) }
    return resampledColors(config.activeColor.colors, count: 3)[1]
}

/// How far the border window reaches past the ring for the glow, on each side. At twice the standard deviation of the
/// blur, what's left of the glow is about 2% of its opacity: the edge of the border window doesn't show. The margin
/// fits the largest radius of the glow, at the peak of the focus pulse. 0 without glow, so that the border windows
/// keep their size
func borderGlowMargin(_ config: BordersConfig) -> CGFloat {
    guard config.glowRadius > 0 else { return 0 }
    let largestRadius = borderGlowPulse(config)?.peakRadius ?? CGFloat(config.glowRadius)
    return (2 * largestRadius).rounded(.up)
}

/// Each growth is relative to the resting glow
let glowPulseRadiusGrowth: CGFloat = 1.6
let glowPulseOpacityGrowth: CGFloat = 1.5

/// The glow grows from its rest to its peak and back, once, when a window gains focus
struct BorderGlowPulse: Equatable {
    let restRadius: CGFloat
    let peakRadius: CGFloat
    let restOpacity: CGFloat
    let peakOpacity: CGFloat
    let duration: CFTimeInterval
}

/// nil when the pulse or the glow is disabled
func borderGlowPulse(_ config: BordersConfig) -> BorderGlowPulse? {
    guard config.focusPulseMs > 0, let active = borderGlowStyle(config, role: .active) else { return nil }
    return BorderGlowPulse(
        restRadius: active.radius,
        peakRadius: active.radius * glowPulseRadiusGrowth,
        restOpacity: active.opacity,
        peakOpacity: min(1, active.opacity * glowPulseOpacityGrowth),
        duration: CFTimeInterval(config.focusPulseMs) / 1000,
    )
}
