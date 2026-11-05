import AppKit
import Common

/// A border window. It's drawn by Core Animation only: no drawRect, no bitmap, nothing to redraw when it moves or
/// resizes. The color transitions and the rotations of the gradient are animations of the render server, they don't
/// wake up the main thread. The glow is a shadow with an explicit path: the render server draws it once per change,
/// without an offscreen pass to find its shape
@MainActor
final class BorderPanel: NSPanel, BorderOverlay {
    private let config: BordersConfig
    /// Inset by ``glowMargin`` in the root layer. A solid border is the `border*` properties of this layer
    private let ringLayer = CALayer()
    /// Only for the gradients
    private let gradient: CAGradientLayer?
    /// Only with a glow. See ``BorderLayerFrames``
    private let glow: (clip: CALayer, shadow: CALayer)?
    private let glowMargin: CGFloat
    private var role: BorderRole = .inactive
    private var ring: BorderRing?
    private var isShown = false

    init(_ config: BordersConfig) {
        self.config = config
        let view = NSView()
        view.wantsLayer = true
        let root = view.layer.orDie()
        let isGradient = config.activeColor.isGradient || config.inactiveColor?.isGradient == true
        gradient = isGradient ? CAGradientLayer() : nil
        glowMargin = borderGlowMargin(config)
        glow = borderGlowStyle(config, role: .inactive) != nil ? (clip: CALayer(), shadow: CALayer()) : nil
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = view
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // No canJoinAllSpaces: a border belongs to the Space of its window. Otherwise, it would show up over
        // the native fullscreen apps, which have their own Spaces
        collectionBehavior = [.ignoresCycle, .fullScreenNone]

        if let glow {
            // The mask goes on a container: it clips everything the container composites, the shadow of its sublayer included
            let clip = CALayer()
            clip.cornerCurve = .continuous
            clip.borderColor = CGColor(gray: 0, alpha: 1)
            glow.clip.mask = clip
            glow.shadow.shadowOffset = .zero
            glow.clip.addSublayer(glow.shadow)
            root.addSublayer(glow.clip)
        }
        // The ring covers the glow, which only shows outside of the ring
        root.addSublayer(ringLayer)
        if let gradient {
            // The ring is the mask, and the gradient below shows through it
            let ring = CALayer()
            ring.cornerCurve = .continuous
            ring.borderColor = CGColor(gray: 0, alpha: 1)
            ringLayer.mask = ring
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.setAffineTransform(CGAffineTransform(rotationAngle: gradientRotation(degrees: config.gradientAngle)))
            ringLayer.addSublayer(gradient)
        } else {
            ringLayer.cornerCurve = .continuous
        }
        applyColors(of: role)
    }

    /// `frame` is in AppKit coordinates
    func place(_ frame: CGRect, ring: BorderRing, level: Int) {
        if self.level.rawValue != level { self.level = NSWindow.Level(rawValue: level) }
        if frame.size == self.frame.size {
            if ring != self.ring { layout(ring: ring, size: frame.size) }
            // Most of the moves keep the size, and a pure move doesn't need any layout
            if frame.origin != self.frame.origin { setFrameOrigin(frame.origin) }
            return
        }
        setFrame(frame, display: false)
        layout(ring: ring, size: frame.size)
    }

    func setRole(_ newRole: BorderRole, animated: Bool) {
        if newRole == role { return }
        let previousRole = role
        role = newRole
        let duration = animated ? CFTimeInterval(config.transitionMs) / 1000 : 0
        let glowFrom = glow.map { glow in
            let presentation = glow.shadow.presentation() ?? glow.shadow
            return (opacity: presentation.shadowOpacity, color: presentation.shadowColor)
        }
        if let gradient {
            let from = gradient.presentation()?.colors ?? gradient.colors
            applyColors(of: newRole)
            if duration > 0, let from { gradient.add(transition("colors", from: from, duration), forKey: "colors") }
        } else {
            let from = ringLayer.presentation()?.borderColor ?? ringLayer.borderColor
            applyColors(of: newRole)
            if duration > 0, let from { ringLayer.add(transition("borderColor", from: from, duration), forKey: "borderColor") }
        }
        if duration > 0, let glow, let glowFrom {
            if glowFrom.opacity != glow.shadow.shadowOpacity {
                glow.shadow.add(transition("shadowOpacity", from: glowFrom.opacity, duration), forKey: "glowOpacity")
            }
            if let color = glowFrom.color, color != glow.shadow.shadowColor {
                glow.shadow.add(transition("shadowColor", from: color, duration), forKey: "glowColor")
            }
        }
        if animated && newRole == .active && previousRole == .inactive {
            sweep()
            pulse()
        }
        syncSpin()
    }

    func show(nextTo target: (nativeWindowId: UInt32, above: Bool)?) {
        if isShown { return }
        isShown = true
        if let target {
            // Window numbers are global to the WindowServer, so AppKit can order relative to the window of another app
            order(target.above ? .above : .below, relativeTo: Int(target.nativeWindowId))
        } else {
            orderFrontRegardless()
        }
        syncSpin()
    }

    func reorder(nextTo target: (nativeWindowId: UInt32, above: Bool)) {
        if !isShown { return }
        order(target.above ? .above : .below, relativeTo: Int(target.nativeWindowId))
    }

    func hide() {
        if !isShown { return }
        isShown = false
        orderOut(nil)
        syncSpin()
    }

    func dispose() {
        isShown = false
        close()
    }

    /// The ring is the mask of a gradient, or the border of ``ringLayer`` itself for a solid color
    private func layout(ring: BorderRing, size: CGSize) {
        self.ring = ring
        let frames = borderLayerFrames(size: size, ring: ring, width: CGFloat(config.width), glowMargin: glowMargin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.frame = frames.ring
        let ringBounds = CGRect(origin: .zero, size: frames.ring.size)
        let ringShape = ringLayer.mask ?? ringLayer
        ringLayer.mask?.frame = ringBounds
        ringShape.borderWidth = ring.lineWidth
        ringShape.cornerRadius = ring.cornerRadius
        if let gradient {
            let side = hypot(ringBounds.width, ringBounds.height)
            // bounds and position, not frame: frame is undefined for a rotated layer
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.position = CGPoint(x: ringBounds.midX, y: ringBounds.midY)
            gradient.locations = gradientLocations(count: stopCount, size: ringBounds.size, degrees: config.gradientAngle).map { $0 as NSNumber }
        }
        if let glow {
            let bounds = CGRect(origin: .zero, size: size)
            glow.clip.frame = bounds
            glow.clip.mask?.frame = bounds
            glow.clip.mask?.borderWidth = frames.glowClipWidth
            glow.clip.mask?.cornerRadius = frames.glowClipCornerRadius
            glow.shadow.frame = bounds
            let radius = frames.glowShapeCornerRadius
            glow.shadow.shadowPath = CGPath(roundedRect: frames.glowShape, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        CATransaction.commit()
    }

    private var stopCount: Int { max(config.activeColor.colors.count, config.inactiveColor?.colors.count ?? 1, 2) }

    private func paint(of role: BorderRole) -> BorderPaint? {
        switch role {
            case .active: config.activeColor
            case .inactive: config.inactiveColor
        }
    }

    private func applyColors(of role: BorderRole) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The controller never shows an inactive border without an inactive color. Transparent is only what
        // the active border fades in from
        let colors = paint(of: role)?.colors ?? [ArgbColor(argb: 0)]
        if let gradient {
            gradient.colors = resampledColors(colors, count: stopCount).map(\.cgColor)
        } else {
            ringLayer.borderColor = RgbaComponents(colors[0]).cgColor
        }
        if let glow, let style = borderGlowStyle(config, role: role) {
            glow.shadow.shadowColor = style.color.cgColor
            glow.shadow.shadowRadius = style.radius
            glow.shadow.shadowOpacity = Float(style.opacity)
        }
        CATransaction.commit()
    }

    private func transition(_ keyPath: String, from: Any, _ duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }

    /// One turn of the gradient, ending where it rests
    private func sweep() {
        guard let gradient, config.focusSweepMs > 0, config.angleAnimationPeriodMs == 0 else { return }
        let rest = gradientRotation(degrees: config.gradientAngle)
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = rest + 2 * .pi
        animation.toValue = rest
        animation.duration = CFTimeInterval(config.focusSweepMs) / 1000
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.add(animation, forKey: "sweep")
    }

    /// The pulse adds to the glow instead of replacing it, so that it rides on the fade in of the focus transition,
    /// which animates the same `shadowOpacity`
    private func pulse() {
        guard let glow, let pulse = borderGlowPulse(config) else { return }
        func bump(_ keyPath: String, by peak: CGFloat) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = [0, peak, 0]
            animation.keyTimes = [0, 0.5, 1]
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            animation.isAdditive = true
            animation.duration = pulse.duration
            return animation
        }
        let group = CAAnimationGroup()
        group.animations = [
            bump("shadowRadius", by: pulse.peakRadius - pulse.restRadius),
            bump("shadowOpacity", by: pulse.peakOpacity - pulse.restOpacity),
        ]
        group.duration = pulse.duration
        glow.shadow.add(group, forKey: "glowPulse")
    }

    /// The continuous rotation runs only on the visible active border. A hidden window would keep the render
    /// server busy for nothing
    private func syncSpin() {
        guard let gradient else { return }
        let shouldSpin = config.angleAnimationPeriodMs > 0 && isShown && role == .active
        let isSpinning = gradient.animation(forKey: "spin") != nil
        if shouldSpin == isSpinning { return }
        if shouldSpin {
            let rest = gradientRotation(degrees: config.gradientAngle)
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = rest
            animation.toValue = rest - 2 * .pi // Clockwise on the screen, like gradient-angle
            animation.duration = CFTimeInterval(config.angleAnimationPeriodMs) / 1000
            animation.repeatCount = .infinity
            gradient.add(animation, forKey: "spin")
        } else {
            gradient.removeAnimation(forKey: "spin")
        }
    }
}
