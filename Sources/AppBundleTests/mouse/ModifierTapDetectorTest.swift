@testable import AppBundle
import AppKit
import Common
import Testing

private let lcmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICELCMDKEYMASK))
private let rcmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICERCMDKEYMASK))
private let lalt = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK))
private let ralt = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK))
private let lshift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICELSHIFTKEYMASK))
/// Released modifiers leave the non-coalesced bit set, so a release is rarely an exact zero
private let released = CGEventFlags(rawValue: UInt64(NX_NONCOALSESCEDMASK))

private let ms: UInt64 = 1_000_000

/// Feeds the inputs, each with its time in milliseconds, and returns the taps in order
private func taps(_ inputs: [(ModifierTapInput, UInt64)]) -> [ModifierKey] {
    var detector = ModifierTapDetector()
    return inputs.compactMap { detector.handle($0.0, now: $0.1 * ms) }
}

private let leftCmd = ModifierKey(name: "cmd", side: .left)

struct ModifierTapDetectorTest {
    @Test func cleanTapFires() {
        assertEquals(taps([(.flagsChanged(lcmd), 1000), (.flagsChanged(released), 1100)]), [leftCmd])
    }

    @Test func combinationsDontFire() {
        let cases: [(String, [(ModifierTapInput, UInt64)])] = [
            ("key in between, e.g. cmd-c", [(.flagsChanged(lcmd), 1000), (.other, 1050), (.flagsChanged(released), 1100)]),
            ("mouse click in between, e.g. cmd-click", [(.flagsChanged(lcmd), 1000), (.other, 1050), (.flagsChanged(released), 1100)]),
            ("extra modifier, released last", [(.flagsChanged(lcmd), 1000), (.flagsChanged(lcmd.union(lshift)), 1050), (.flagsChanged(lshift), 1080), (.flagsChanged(released), 1100)]),
            ("extra modifier, released first", [(.flagsChanged(lcmd), 1000), (.flagsChanged(lcmd.union(lshift)), 1050), (.flagsChanged(lcmd), 1080), (.flagsChanged(released), 1100)]),
            ("both sides of the same modifier", [(.flagsChanged(lcmd), 1000), (.flagsChanged(lcmd.union(rcmd)), 1050), (.flagsChanged(lcmd), 1080), (.flagsChanged(released), 1100)]),
            ("fn in between", [(.flagsChanged(lcmd), 1000), (.flagsChanged(lcmd.union(.maskSecondaryFn)), 1050), (.flagsChanged(lcmd), 1080), (.flagsChanged(released), 1100)]),
            ("held too long", [(.flagsChanged(lcmd), 1000), (.flagsChanged(released), 1501)]),
            ("the tap was disabled", [(.flagsChanged(lcmd), 1000), (.tapDisabled, 1050), (.flagsChanged(released), 1100)]),
            ("a release without a press", [(.flagsChanged(released), 1100)]),
            ("pressed together with another modifier", [(.flagsChanged(lcmd.union(lshift)), 1000), (.flagsChanged(released), 1100)]),
        ]
        for (name, inputs) in cases {
            assertEquals(taps(inputs), [], additionalMsg: name)
        }
    }

    @Test func holdThresholdIsInclusive() {
        assertEquals(taps([(.flagsChanged(lcmd), 1000), (.flagsChanged(released), 1500)]), [leftCmd])
    }

    @Test func sides() {
        assertEquals(taps([(.flagsChanged(ralt), 1000), (.flagsChanged(released), 1100)]), [ModifierKey(name: "alt", side: .right)])
        assertEquals(taps([(.flagsChanged(lalt), 1000), (.flagsChanged(released), 1100)]), [ModifierKey(name: "alt", side: .left)])
        // E.g. synthetic events without the device dependent bits
        assertEquals(taps([(.flagsChanged(.maskControl), 1000), (.flagsChanged(released), 1100)]), [ModifierKey(name: "ctrl", side: nil)])
    }

    @Test func repeatedTaps() {
        assertEquals(
            taps([
                (.flagsChanged(lcmd), 1000), (.flagsChanged(released), 1100),
                (.flagsChanged(rcmd), 1200), (.flagsChanged(released), 1300),
                // A spoiled tap doesn't affect the next one
                (.flagsChanged(lcmd), 1400), (.other, 1450), (.flagsChanged(released), 1500),
                (.flagsChanged(lcmd), 1600), (.flagsChanged(released), 1700),
            ]),
            [leftCmd, ModifierKey(name: "cmd", side: .right), leftCmd],
        )
    }

    @Test func otherInputWhileIdleDoesntSpoilTheNextTap() {
        assertEquals(taps([(.other, 900), (.tapDisabled, 950), (.flagsChanged(lcmd), 1000), (.flagsChanged(released), 1100)]), [leftCmd])
    }

    @Test func capsLockStateDoesntMatter() {
        let capsLock = CGEventFlags.maskAlphaShift
        assertEquals(taps([(.flagsChanged(lcmd.union(capsLock)), 1000), (.flagsChanged(capsLock), 1100)]), [leftCmd])
    }

    @Test func resolveBinding() {
        let commands = parseCommand("true").cmdOrDie
        let cmd = ModifierTapBinding(commands: commands, descriptionWithKeyNotation: "cmd")
        let rcmd = ModifierTapBinding(commands: commands, descriptionWithKeyNotation: "rcmd")
        let bindings = ["cmd": cmd, "rcmd": rcmd]
        assertEquals(modifierTapBinding(for: ModifierKey(name: "cmd", side: .right), in: bindings), rcmd)
        assertEquals(modifierTapBinding(for: ModifierKey(name: "cmd", side: .left), in: bindings), cmd)
        assertEquals(modifierTapBinding(for: ModifierKey(name: "cmd", side: nil), in: bindings), cmd)
        assertNil(modifierTapBinding(for: ModifierKey(name: "cmd", side: .left), in: ["rcmd": rcmd]))
        assertNil(modifierTapBinding(for: ModifierKey(name: "alt", side: .left), in: bindings))
    }

    @Test func maskWithoutModifierOnlyBindingsIsTheMouseMask() {
        let mouseMask: CGEventMask = [
            CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
            .otherMouseDown, .otherMouseDragged, .otherMouseUp,
        ].reduce(0) { $0 | (1 << $1.rawValue) }
        assertEquals(inputTapEventMask(listensToKeys: false), mouseMask)
        let keyMask: CGEventMask = [CGEventType.flagsChanged, .keyDown, .scrollWheel].reduce(0) { $0 | (1 << $1.rawValue) }
        assertEquals(inputTapEventMask(listensToKeys: true), mouseMask | keyMask)
        // keyUp isn't needed to spoil a tap, so the tap doesn't ask for it
        assertEquals(inputTapEventMask(listensToKeys: true) & (1 << CGEventType.keyUp.rawValue), 0)
    }
}
