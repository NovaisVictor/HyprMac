import AppKit
import Common

/// Animates the frames that layouts and the scratchpad apply to windows. See `[animations]` in the config.
/// Any other frame write stops the animation of its window (see `Window.setAxFrame`),
/// so an animation never fights with the rest of HyprMac
@MainActor let frameAnimator = FrameAnimator(now: { ContinuousClock.now }, isTickingAutomatically: !isUnitTest)

struct FrameAnimationStyle: Equatable, Sendable {
    let duration: Duration
    let easing: Easing
    /// False writes the position only and applies the size at the end, for apps that are slow to resize
    var animatesSize: Bool = true
}

@MainActor
final class FrameAnimator {
    private struct Animation {
        let window: Window
        let from: Rect
        let to: Rect
        let start: ContinuousClock.Instant
        let style: FrameAnimationStyle
        var current: Rect
        /// Runs once the window lands on `to`. Dropped when the animation is retargeted or canceled:
        /// whoever moved the window elsewhere owns it from then on
        var onComplete: (@MainActor () -> Void)?
    }

    /// 60 Hz. Every frame is an AX request to the app, so there is no point in going faster than most displays
    static let frameInterval: Duration = .microseconds(16667)

    private var animations: [OpaqueWindowId: Animation] = [:]
    private let now: @MainActor () -> ContinuousClock.Instant
    private let isTickingAutomatically: Bool
    private var tickTask: Task<(), any Error>? = nil

    /// `isTickingAutomatically: false` lets tests drive the frames with ``tick()``
    init(now: @escaping @MainActor () -> ContinuousClock.Instant, isTickingAutomatically: Bool) {
        self.now = now
        self.isTickingAutomatically = isTickingAutomatically
    }

    /// The rect the running animation of the window lands on
    func target(of window: Window) -> Rect? { animations[window.windowId]?.to }

    /// Whether ``animate(_:from:to:_:)`` would start or retarget an animation rather than jump or keep going
    func wouldStartAnimation(_ window: Window, from: Rect?, to: Rect, _ style: FrameAnimationStyle) -> Bool {
        if let running = animations[window.windowId] { return running.to != to }
        guard let from else { return false }
        return from != to && style.duration > .zero
    }

    /// `from` is the rect the window had after the previous layout. When it's unknown, the window jumps to `to`.
    /// A window that is already animating starts from where it currently is: the latest target wins.
    /// `onComplete` runs when the window lands, right away if it jumps
    func animate(_ window: Window, from: Rect?, to: Rect, _ style: FrameAnimationStyle, onComplete: (@MainActor () -> Void)? = nil) {
        if let running = animations[window.windowId] {
            if running.to == to {
                if let onComplete { animations[window.windowId]?.onComplete = onComplete }
                return
            }
            start(window, from: running.current, to: to, style, onComplete)
        } else if let from, from != to, style.duration > .zero {
            start(window, from: from, to: to, style, onComplete)
        } else {
            window.setAxFrame(to.topLeftCorner, to.size)
            onComplete?()
        }
    }

    func cancel(_ window: Window) {
        animations.removeValue(forKey: window.windowId)
    }

    /// Unlike ``cancel(_:)``, puts the window where the animation would have landed, and runs its completion
    func finish(_ window: Window) {
        guard let animation = animations.removeValue(forKey: window.windowId) else { return }
        window.setAxFrame(animation.to.topLeftCorner, animation.to.size)
        animation.onComplete?()
    }

    func cancelAll() {
        animations = [:]
    }

    /// Writes one frame of every running animation. Frames are never queued: a slow app only skips frames,
    /// because `setNativeAxFrame` drops the previous write of the window if it hasn't happened yet
    func tick() {
        let now = now()
        for (windowId, animation) in animations {
            let window = animation.window
            guard window.lifeStatus == .alive, window.isBound else {
                animations.removeValue(forKey: windowId)
                continue
            }
            let progress = CGFloat((now - animation.start) / animation.style.duration)
            let isOver = progress >= 1
            let rect: Rect
            window.expectAnimationEcho()
            if isOver {
                // The size is written even if it didn't change, so the window lands exactly in its slot
                rect = animation.to
                window.setNativeAxFrame(rect.topLeftCorner, rect.size)
            } else {
                let interpolated = interpolatedRect(from: animation.from, to: animation.to, progress: animation.style.easing.progress(progress))
                // Every AX write is a request to the app. Resizing is the expensive one, so it's skipped when it
                // isn't needed, or delayed to the end when the config asks for it
                if animation.from.size == animation.to.size || !animation.style.animatesSize {
                    rect = Rect(topLeftX: interpolated.topLeftX, topLeftY: interpolated.topLeftY, width: animation.current.width, height: animation.current.height)
                    window.setNativeAxFrame(rect.topLeftCorner, nil)
                } else {
                    rect = interpolated
                    window.setNativeAxFrame(rect.topLeftCorner, rect.size)
                }
            }
            bordersOnFrameWrite(window, topLeft: rect.topLeftCorner, size: rect.size)
            if isOver {
                animations.removeValue(forKey: windowId)
                animation.onComplete?()
            } else {
                animations[windowId]?.current = rect
            }
        }
    }

    private func start(_ window: Window, from: Rect, to: Rect, _ style: FrameAnimationStyle, _ onComplete: (@MainActor () -> Void)?) {
        animations[window.windowId] = Animation(window: window, from: from, to: to, start: now(), style: style, current: from, onComplete: onComplete)
        if isTickingAutomatically && tickTask == nil {
            tickTask = Task.startUnstructured { @MainActor in
                while !self.animations.isEmpty {
                    try await Task.sleep(for: Self.frameInterval)
                    self.tick()
                }
                self.tickTask = nil
            }
        }
    }
}

/// `progress` may be outside [0, 1] for curves that overshoot. The size never collapses below one point then
func interpolatedRect(from: Rect, to: Rect, progress: CGFloat) -> Rect {
    func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
    return Rect(
        topLeftX: lerp(from.topLeftX, to.topLeftX),
        topLeftY: lerp(from.topLeftY, to.topLeftY),
        width: max(1, lerp(from.width, to.width)),
        height: max(1, lerp(from.height, to.height)),
    )
}
