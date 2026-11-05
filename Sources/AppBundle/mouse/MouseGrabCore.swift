import AppKit
import Common

// Pure part of the mouse grab. Everything here runs on the event tap thread, so it must never block,
// touch AX or MainActor state, or crash

struct MouseGrabTrigger: Equatable, Sendable {
    /// Only shift, ctrl, alt and cmd. See `mouseGrabModifierMask`
    let modifiers: CGEventFlags
    /// The device dependent bits of the side-specific modifiers (e.g. `lalt`). See `modifierSideMasks`
    let sideSpecificModifiers: CGEventFlags
    let button: MouseButton
    let kind: GrabKind

    init(modifiers: CGEventFlags, sideSpecificModifiers: CGEventFlags = [], button: MouseButton, kind: GrabKind) {
        self.modifiers = modifiers
        self.sideSpecificModifiers = sideSpecificModifiers
        self.button = button
        self.kind = kind
    }

    /// The modifiers must match exactly. For a side-specific modifier, the pressed sides must match exactly too,
    /// otherwise either side matches
    func matches(_ button: MouseButton, flags: CGEventFlags) -> Bool {
        guard self.button == button && flags.intersection(mouseGrabModifierMask) == modifiers else { return false }
        var sideMask: CGEventFlags = []
        for masks in modifierSideMasks where !sideSpecificModifiers.isDisjoint(with: masks.bothSides) {
            sideMask.formUnion(masks.bothSides)
        }
        return flags.intersection(sideMask) == sideSpecificModifiers
    }

    /// The number of the side-specific modifiers. A side-specific binding wins over the generic one
    var specificity: Int {
        modifierSideMasks.count(where: { !sideSpecificModifiers.isDisjoint(with: $0.bothSides) })
    }
}

struct ModifierSideMasks: Sendable {
    /// The name in the binding notation
    let name: String
    let modifier: NSEvent.ModifierFlags
    let left: CGEventFlags
    let right: CGEventFlags

    var bothSides: CGEventFlags { left.union(right) }
}

/// The device dependent bits that tell the left and the right key of a modifier apart (IOKit/hidsystem/IOLLEvent.h).
/// In the order of NSEvent.ModifierFlags.toString
let modifierSideMasks: [ModifierSideMasks] = [
    ModifierSideMasks(name: "alt", modifier: .option, left: .init(nxDeviceMask: NX_DEVICELALTKEYMASK), right: .init(nxDeviceMask: NX_DEVICERALTKEYMASK)),
    ModifierSideMasks(name: "ctrl", modifier: .control, left: .init(nxDeviceMask: NX_DEVICELCTLKEYMASK), right: .init(nxDeviceMask: NX_DEVICERCTLKEYMASK)),
    ModifierSideMasks(name: "cmd", modifier: .command, left: .init(nxDeviceMask: NX_DEVICELCMDKEYMASK), right: .init(nxDeviceMask: NX_DEVICERCMDKEYMASK)),
    ModifierSideMasks(name: "shift", modifier: .shift, left: .init(nxDeviceMask: NX_DEVICELSHIFTKEYMASK), right: .init(nxDeviceMask: NX_DEVICERSHIFTKEYMASK)),
]

extension CGEventFlags {
    fileprivate init(nxDeviceMask: Int32) {
        self.init(rawValue: UInt64(nxDeviceMask))
    }
}

struct MouseGrabTapSnapshot: Sendable {
    var isEnabled: Bool
    var triggers: [MouseGrabTrigger]
    /// The frontmost app is in `mouse-grab.ignore-app-ids`. Precomputed on the main thread,
    /// because the tap can't afford to look up apps or windows
    var isFrontmostAppIgnored: Bool = false

    static let disabled = MouseGrabTapSnapshot(isEnabled: false, triggers: [])
}

enum MouseGrabTapState: Equatable, Sendable {
    case idle
    case grabbing(MouseButton)
}

enum MouseInput: Equatable, Sendable {
    case down(MouseButton)
    case dragged(MouseButton)
    case up(MouseButton)
    case tapDisabled
}

enum MouseGrabTapEvent: Equatable, Sendable {
    case begin(GrabKind, MouseButton, CGPoint)
    case drag(CGPoint)
    case end(CGPoint)
    case cancel
}

struct MouseGrabClassification: Equatable, Sendable {
    let swallow: Bool
    let newState: MouseGrabTapState
    let event: MouseGrabTapEvent?
}

/// Caps lock, fn, numpad and the device dependent bits must not prevent a binding from matching.
/// The device dependent bits are checked only for the side-specific modifiers. See MouseGrabTrigger.matches
let mouseGrabModifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

extension NSEvent.ModifierFlags {
    var asCgEventFlags: CGEventFlags {
        var result: CGEventFlags = []
        if contains(.shift) { result.insert(.maskShift) }
        if contains(.control) { result.insert(.maskControl) }
        if contains(.option) { result.insert(.maskAlternate) }
        if contains(.command) { result.insert(.maskCommand) }
        return result
    }
}

func classifyMouseInput(
    _ input: MouseInput,
    flags: CGEventFlags,
    point: CGPoint,
    state: MouseGrabTapState,
    snapshot: MouseGrabTapSnapshot,
) -> MouseGrabClassification {
    let pass = MouseGrabClassification(swallow: false, newState: state, event: nil)
    if !snapshot.isEnabled || input == .tapDisabled {
        return switch state {
            case .idle: MouseGrabClassification(swallow: false, newState: .idle, event: nil)
            case .grabbing: MouseGrabClassification(swallow: false, newState: .idle, event: .cancel)
        }
    }
    switch (input, state) {
        case (.down, .idle) where snapshot.isFrontmostAppIgnored:
            // A grab that is already in progress isn't affected, otherwise its drags and up would leak to the app
            return pass
        case (.down(let button), .idle):
            var matching: MouseGrabTrigger? = nil
            // The first of the most specific ones, so that the result doesn't depend on anything but the order of the triggers
            for trigger in snapshot.triggers where trigger.matches(button, flags: flags) {
                if matching.map({ trigger.specificity > $0.specificity }) ?? true { matching = trigger }
            }
            guard let trigger = matching else { return pass }
            return MouseGrabClassification(swallow: true, newState: .grabbing(button), event: .begin(trigger.kind, button, point))
        case (.down(let button), .grabbing(let grabbed)) where button == grabbed:
            // The up of the grabbed button was lost (e.g. the tap was disabled or another app took the mouse).
            // Classify the press as if the grab had ended, so a stale grab can't swallow clicks forever
            let fresh = classifyMouseInput(input, flags: flags, point: point, state: .idle, snapshot: snapshot)
            return fresh.event == nil
                ? MouseGrabClassification(swallow: fresh.swallow, newState: fresh.newState, event: .cancel)
                : fresh
        case (.dragged, .grabbing):
            // Swallow drags even if the modifiers were released, the app must not see a drag it never saw the press of
            return MouseGrabClassification(swallow: true, newState: state, event: .drag(point))
        case (.up(let button), .grabbing(let grabbed)) where button == grabbed:
            return MouseGrabClassification(swallow: true, newState: .idle, event: .end(point))
        case (.down, _), (.dragged, .idle), (.up, _), (.tapDisabled, _):
            return pass
    }
}

/// The button is already physically released when its up event arrives, so only the events before it
/// can use the button state to detect a lost up
func isMouseGrabStillValid(isWindowGrabbable: Bool, isButtonPressed: Bool, isFinalEvent: Bool) -> Bool {
    isWindowGrabbable && (isFinalEvent || isButtonPressed)
}

/// The rect of a window moved by the mouse, given the window rect and the mouse location at the grab start
func movedRect(_ startRect: Rect, startMouse: CGPoint, mouse: CGPoint) -> Rect {
    startRect.with(\.topLeftX, startRect.topLeftX + mouse.x - startMouse.x)
        .with(\.topLeftY, startRect.topLeftY + mouse.y - startMouse.y)
}

/// The edges that follow the mouse during a resize grab: the ones of the corner nearest to the grab point
struct ResizeCorner: Equatable, Sendable {
    let movesLeftEdge: Bool
    let movesTopEdge: Bool

    init(movesLeftEdge: Bool, movesTopEdge: Bool) {
        self.movesLeftEdge = movesLeftEdge
        self.movesTopEdge = movesTopEdge
    }

    init(nearestTo point: CGPoint, of rect: Rect) {
        self.init(movesLeftEdge: point.x < rect.center.x, movesTopEdge: point.y < rect.center.y)
    }
}

/// Keeps the window usable and stops the moving edges from crossing the fixed ones
let minGrabResizeSize = CGSize(width: 100, height: 60)

func resizedRect(_ startRect: Rect, corner: ResizeCorner, startMouse: CGPoint, mouse: CGPoint) -> Rect {
    let dx = mouse.x - startMouse.x
    let dy = mouse.y - startMouse.y
    var minX = startRect.minX
    var maxX = startRect.maxX
    var minY = startRect.minY
    var maxY = startRect.maxY
    if corner.movesLeftEdge {
        minX = min(minX + dx, maxX - minGrabResizeSize.width)
    } else {
        maxX = max(maxX + dx, minX + minGrabResizeSize.width)
    }
    if corner.movesTopEdge {
        minY = min(minY + dy, maxY - minGrabResizeSize.height)
    } else {
        maxY = max(maxY + dy, minY + minGrabResizeSize.height)
    }
    return Rect(topLeftX: minX, topLeftY: minY, width: maxX - minX, height: maxY - minY)
}
