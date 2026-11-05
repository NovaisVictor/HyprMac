import AppKit
import Common

// Pure part of the modifier-only bindings. It runs on the event tap thread, so it must never block,
// touch AX or MainActor state, or crash

enum ModifierSide: Equatable, Sendable {
    case left, right

    var notationPrefix: String {
        switch self {
            case .left: "l"
            case .right: "r"
        }
    }
}

/// A physical modifier key
struct ModifierKey: Hashable, Sendable {
    /// The name in the binding notation, e.g. `cmd`. See `modifierSideMasks`
    let name: String
    /// nil when the event doesn't carry the device dependent bits, e.g. some synthetic events
    let side: ModifierSide?
}

enum ModifierTapInput: Equatable, Sendable {
    case flagsChanged(CGEventFlags)
    /// Anything that turns a tap into a combination: a key press, a mouse button press, a scroll, or one of our hotkeys
    case other
    /// The tap was disabled, so events may have been lost
    case tapDisabled
}

/// A tap held longer than this is a cancelled combination, not a tap: the user pressed the modifier for a shortcut
/// and changed their mind. Comfortably above a deliberate tap (typically 100-250 ms), and below the time it takes to
/// notice a mistake. A constant rather than a config option: nobody asked to tune it yet. Karabiner's similar
/// `to_if_alone_timeout_milliseconds` defaults to 1000 ms, but it also has to handle remapped keys that are held on purpose
let modifierTapMaxHoldNanoseconds: UInt64 = 500_000_000

/// Detects a modifier that is pressed and released with nothing else in between
struct ModifierTapDetector: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        /// No modifier is pressed
        case idle
        /// Exactly one modifier is pressed, and nothing else happened since
        case armed(ModifierKey, since: UInt64, otherFlags: CGEventFlags)
        /// Modifiers are pressed, but they can't make a tap anymore. Waits until all of them are released
        case spoiled
    }

    private var state: State = .idle
    private let maxHoldNanoseconds: UInt64

    init(maxHoldNanoseconds: UInt64 = modifierTapMaxHoldNanoseconds) {
        self.maxHoldNanoseconds = maxHoldNanoseconds
    }

    /// Returns the tapped key, when `input` completes a tap. `now` is a monotonic time in nanoseconds
    mutating func handle(_ input: ModifierTapInput, now: UInt64) -> ModifierKey? {
        switch input {
            case .other, .tapDisabled:
                // While idle, nothing is lost: the next flagsChanged tells which modifiers are pressed, and a release
                // that arrives while idle never fires
                if state != .idle { state = .spoiled }
                return nil
            case .flagsChanged(let flags):
                let pressed = pressedModifierKeys(flags)
                let otherFlags = flags.intersection(modifierTapOtherFlags)
                if pressed.isEmpty {
                    defer { state = .idle }
                    guard case .armed(let key, let since, _) = state, now >= since, now - since <= maxHoldNanoseconds else { return nil }
                    return key
                }
                switch state {
                    case .idle where pressed.count == 1:
                        state = .armed(pressed[0], since: now, otherFlags: otherFlags)
                    case .armed(let key, _, let armedOtherFlags) where pressed == [key] && otherFlags == armedOtherFlags:
                        break
                    case .idle, .armed, .spoiled:
                        state = .spoiled
                }
                return nil
        }
    }
}

/// The flags of the keys that aren't bindable modifiers, but still turn a tap into a combination (e.g. `fn`)
private let modifierTapOtherFlags: CGEventFlags = [.maskSecondaryFn, .maskAlphaShift, .maskHelp]

func pressedModifierKeys(_ flags: CGEventFlags) -> [ModifierKey] {
    var result: [ModifierKey] = []
    for masks in modifierSideMasks where flags.contains(masks.modifier.asCgEventFlags) {
        let isLeft = !flags.isDisjoint(with: masks.left)
        let isRight = !flags.isDisjoint(with: masks.right)
        if isLeft { result.append(ModifierKey(name: masks.name, side: .left)) }
        if isRight { result.append(ModifierKey(name: masks.name, side: .right)) }
        if !isLeft && !isRight { result.append(ModifierKey(name: masks.name, side: nil)) }
    }
    return result
}
