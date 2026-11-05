@testable import AppBundle
import AppKit
import Common
import Testing

private let alt: CGEventFlags = .maskAlternate
private let point = CGPoint(x: 10, y: 20)
private let snapshot = MouseGrabTapSnapshot(isEnabled: true, triggers: [
    MouseGrabTrigger(modifiers: .maskAlternate, button: .left, kind: .move),
    MouseGrabTrigger(modifiers: [.maskAlternate, .maskShift], button: .right, kind: .resize),
])

private func classify(
    _ input: MouseInput,
    _ flags: CGEventFlags = alt,
    _ state: MouseGrabTapState = .idle,
    _ snapshot: MouseGrabTapSnapshot = snapshot,
) -> MouseGrabClassification {
    classifyMouseInput(input, flags: flags, point: point, state: state, snapshot: snapshot)
}

private let passIdle = MouseGrabClassification(swallow: false, newState: .idle, event: nil)

struct MouseGrabCoreTest {
    @Test func testReleasedButtonEndsGrabNormallyOnlyOnFinalEvent() {
        // Regression: the up event arrives after the button is physically released, and used to cancel every grab
        assertTrue(isMouseGrabStillValid(isWindowGrabbable: true, isButtonPressed: false, isFinalEvent: true))
        assertTrue(!isMouseGrabStillValid(isWindowGrabbable: true, isButtonPressed: false, isFinalEvent: false))
        assertTrue(isMouseGrabStillValid(isWindowGrabbable: true, isButtonPressed: true, isFinalEvent: false))
        assertTrue(!isMouseGrabStillValid(isWindowGrabbable: false, isButtonPressed: true, isFinalEvent: true))
    }

    @Test func testMatchingDownStartsGrab() {
        assertEquals(classify(.down(.left)), MouseGrabClassification(swallow: true, newState: .grabbing(.left), event: .begin(.move, .left, point)))
        assertEquals(
            classify(.down(.right), [.maskAlternate, .maskShift]),
            MouseGrabClassification(swallow: true, newState: .grabbing(.right), event: .begin(.resize, .right, point)),
        )
    }

    @Test func testModifiersMustMatchExactly() {
        assertEquals(classify(.down(.left), []), passIdle)
        assertEquals(classify(.down(.left), [.maskAlternate, .maskCommand]), passIdle)
        assertEquals(classify(.down(.right), alt), passIdle)
    }

    @Test func testIrrelevantFlagsAreIgnored() {
        let flags: CGEventFlags = [.maskAlternate, .maskAlphaShift, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        assertEquals(classify(.down(.left), flags).event, .begin(.move, .left, point))
    }

    @Test func testButtonMismatchPassesThrough() {
        assertEquals(classify(.down(.middle)), passIdle)
        assertEquals(classify(.dragged(.left)), passIdle)
        assertEquals(classify(.up(.left)), passIdle)
    }

    @Test func testGrabSwallowsDragsAndUpEvenWithoutModifiers() {
        let grabbing = MouseGrabTapState.grabbing(.left)
        assertEquals(classify(.dragged(.left), [], grabbing), MouseGrabClassification(swallow: true, newState: grabbing, event: .drag(point)))
        assertEquals(classify(.up(.left), [], grabbing), MouseGrabClassification(swallow: true, newState: .idle, event: .end(point)))
    }

    @Test func testOtherButtonsPassThroughDuringGrab() {
        let grabbing = MouseGrabTapState.grabbing(.left)
        assertEquals(classify(.down(.right), alt, grabbing), MouseGrabClassification(swallow: false, newState: grabbing, event: nil))
        assertEquals(classify(.up(.right), alt, grabbing), MouseGrabClassification(swallow: false, newState: grabbing, event: nil))
    }

    @Test func testStaleGrabIsRepairedOnNextDown() {
        let grabbing = MouseGrabTapState.grabbing(.left)
        // The up was lost, and the new press is a plain click: it must reach the app
        assertEquals(classify(.down(.left), [], grabbing), MouseGrabClassification(swallow: false, newState: .idle, event: .cancel))
        // The up was lost, and the new press starts a new grab
        assertEquals(classify(.down(.left), alt, grabbing), MouseGrabClassification(swallow: true, newState: grabbing, event: .begin(.move, .left, point)))
    }

    @Test func testIgnoredFrontmostAppPassesClicksThrough() {
        var ignoring = snapshot
        ignoring.isFrontmostAppIgnored = true
        assertEquals(classify(.down(.left), alt, .idle, ignoring), passIdle)
        assertEquals(classify(.down(.right), [.maskAlternate, .maskShift], .idle, ignoring), passIdle)
        assertEquals(classify(.dragged(.left), alt, .idle, ignoring), passIdle)
        assertEquals(classify(.up(.left), alt, .idle, ignoring), passIdle)
    }

    @Test func testIgnoredFrontmostAppDoesntBreakGrabInProgress() {
        // E.g. the grab activated the ignored app
        var ignoring = snapshot
        ignoring.isFrontmostAppIgnored = true
        let grabbing = MouseGrabTapState.grabbing(.left)
        assertEquals(classify(.dragged(.left), alt, grabbing, ignoring), MouseGrabClassification(swallow: true, newState: grabbing, event: .drag(point)))
        assertEquals(classify(.up(.left), alt, grabbing, ignoring), MouseGrabClassification(swallow: true, newState: .idle, event: .end(point)))
        // The up was lost: the stale grab is cancelled, and the press reaches the ignored app
        assertEquals(classify(.down(.left), alt, grabbing, ignoring), MouseGrabClassification(swallow: false, newState: .idle, event: .cancel))
    }

    @Test func testDisabledTapCancelsGrab() {
        assertEquals(classify(.tapDisabled, alt, .grabbing(.left)), MouseGrabClassification(swallow: false, newState: .idle, event: .cancel))
        assertEquals(classify(.tapDisabled, alt, .idle), passIdle)
    }

    @Test func testDisabledServerPassesEverythingThrough() {
        assertEquals(classify(.down(.left), alt, .idle, .disabled), passIdle)
        assertEquals(classify(.dragged(.left), alt, .grabbing(.left), .disabled), MouseGrabClassification(swallow: false, newState: .idle, event: .cancel))
    }

    @Test func testEveryGrabEndsIdle() {
        typealias Step = (input: MouseInput, flags: CGEventFlags, snapshot: MouseGrabTapSnapshot)
        let sequences: [[Step]] = [
            [(.down(.left), alt, snapshot), (.dragged(.left), alt, snapshot), (.tapDisabled, alt, snapshot)],
            [(.down(.left), alt, snapshot), (.dragged(.left), [], snapshot), (.up(.left), [], snapshot)],
            [(.down(.left), alt, snapshot), (.down(.left), [], snapshot)], // The up was lost
            [(.down(.left), alt, snapshot), (.dragged(.left), alt, .disabled)], // hyprmac enable off
        ]
        for sequence in sequences {
            var state = MouseGrabTapState.idle
            var events: [MouseGrabTapEvent] = []
            for step in sequence {
                let result = classify(step.input, step.flags, state, step.snapshot)
                state = result.newState
                events += result.event.map { [$0] } ?? []
            }
            assertEquals(state, .idle)
            assertEquals(events.first, .begin(.move, .left, point))
            assertTrue(events.last == .cancel || events.last == .end(point))
        }
    }

    @Test func testSideSpecificModifiers() {
        let lAlt = CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))
        let rAlt = CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))
        let lShift = CGEventFlags(rawValue: UInt64(NX_DEVICELSHIFTKEYMASK))
        let rShift = CGEventFlags(rawValue: UInt64(NX_DEVICERSHIFTKEYMASK))
        let lCmd = CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))
        let sideSnapshot = MouseGrabTapSnapshot(isEnabled: true, triggers: [
            MouseGrabTrigger(modifiers: .maskAlternate, button: .left, kind: .move), // alt
            MouseGrabTrigger(modifiers: .maskAlternate, sideSpecificModifiers: rAlt, button: .left, kind: .resize), // ralt
            MouseGrabTrigger(modifiers: [.maskAlternate, .maskShift], sideSpecificModifiers: lShift, button: .right, kind: .move), // alt-lshift
            MouseGrabTrigger(modifiers: .maskCommand, sideSpecificModifiers: lCmd, button: .middle, kind: .move), // lcmd
        ])
        let cases: [(button: MouseButton, flags: CGEventFlags, expected: GrabKind?)] = [
            // The generic modifier keeps matching either side, unless a side-specific binding takes that side
            (.left, [.maskAlternate, lAlt], .move),
            (.left, [.maskAlternate, rAlt], .resize),
            (.left, [.maskAlternate, lAlt, rAlt], .move),
            // No device bits at all (e.g. a synthetic event)
            (.left, .maskAlternate, .move),
            (.left, [.maskAlternate, lAlt, .maskShift, lShift], nil),
            // The side-specific modifier requires its side, and only it
            (.right, [.maskAlternate, .maskShift, lShift], .move),
            (.right, [.maskAlternate, rAlt, .maskShift, lShift], .move),
            (.right, [.maskAlternate, .maskShift, rShift], nil),
            (.right, [.maskAlternate, .maskShift, lShift, rShift], nil),
            (.right, [.maskAlternate, .maskShift], nil),
            (.right, [.maskShift, lShift], nil),
            (.middle, [.maskCommand, lCmd], .move),
            (.middle, [.maskCommand, lCmd, .maskAlphaShift, .maskSecondaryFn], .move),
            (.middle, [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))], nil),
            (.middle, [.maskCommand, lCmd, .maskControl, CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK))], nil),
        ]
        for (button, flags, expected) in cases {
            let result = classify(.down(button), flags, .idle, sideSnapshot)
            assertEquals(result.event, expected.map { .begin($0, button, point) }, additionalMsg: "\(button) \(flags.rawValue)")
            assertEquals(result.swallow, expected != nil, additionalMsg: "\(button) \(flags.rawValue)")
        }
    }

    @Test func testMostSpecificTriggerWinsRegardlessOfOrder() {
        let rAlt = CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))
        let generic = MouseGrabTrigger(modifiers: .maskAlternate, button: .left, kind: .move)
        let specific = MouseGrabTrigger(modifiers: .maskAlternate, sideSpecificModifiers: rAlt, button: .left, kind: .resize)
        for triggers in [[generic, specific], [specific, generic]] {
            let result = classify(.down(.left), [.maskAlternate, rAlt], .idle, MouseGrabTapSnapshot(isEnabled: true, triggers: triggers))
            assertEquals(result.event, .begin(.resize, .left, point))
        }
    }

    @Test func testSideMasksMatchSdkHeader() {
        // IOKit/hidsystem/IOLLEvent.h
        assertEquals(modifierSideMasks.map(\.name), ["alt", "ctrl", "cmd", "shift"])
        assertEquals(modifierSideMasks.map(\.left.rawValue), [0x20, 0x1, 0x8, 0x2])
        assertEquals(modifierSideMasks.map(\.right.rawValue), [0x40, 0x2000, 0x10, 0x4])
    }

    @Test func testModifierFlagsConversion() {
        assertEquals(NSEvent.ModifierFlags([.option, .shift]).asCgEventFlags, [.maskAlternate, .maskShift])
        assertEquals(NSEvent.ModifierFlags([.control, .command]).asCgEventFlags, [.maskControl, .maskCommand])
    }

    @Test func testMovedRect() {
        let rect = movedRect(Rect(topLeftX: 100, topLeftY: 100, width: 300, height: 200), startMouse: CGPoint(x: 150, y: 150), mouse: CGPoint(x: 100, y: 250))
        assertEquals(rect.topLeftCorner, CGPoint(x: 50, y: 200))
        assertEquals(rect.size, CGSize(width: 300, height: 200))
    }
}

struct MouseGrabResizeGeometryTest {
    private let start = Rect(topLeftX: 100, topLeftY: 100, width: 400, height: 300)

    @Test func testCornerIsChosenByQuadrant() {
        assertEquals(ResizeCorner(nearestTo: CGPoint(x: 120, y: 120), of: start), ResizeCorner(movesLeftEdge: true, movesTopEdge: true))
        assertEquals(ResizeCorner(nearestTo: CGPoint(x: 480, y: 120), of: start), ResizeCorner(movesLeftEdge: false, movesTopEdge: true))
        assertEquals(ResizeCorner(nearestTo: CGPoint(x: 120, y: 380), of: start), ResizeCorner(movesLeftEdge: true, movesTopEdge: false))
        assertEquals(ResizeCorner(nearestTo: CGPoint(x: 480, y: 380), of: start), ResizeCorner(movesLeftEdge: false, movesTopEdge: false))
    }

    @Test func testBottomRightCornerFollowsMouse() {
        let rect = resizedRect(start, corner: ResizeCorner(movesLeftEdge: false, movesTopEdge: false), startMouse: CGPoint(x: 480, y: 380), mouse: CGPoint(x: 530, y: 360))
        assertEquals(rect.topLeftCorner, CGPoint(x: 100, y: 100))
        assertEquals(rect.size, CGSize(width: 450, height: 280))
    }

    @Test func testTopLeftCornerFollowsMouse() {
        let rect = resizedRect(start, corner: ResizeCorner(movesLeftEdge: true, movesTopEdge: true), startMouse: CGPoint(x: 120, y: 120), mouse: CGPoint(x: 70, y: 140))
        assertEquals(rect.topLeftCorner, CGPoint(x: 50, y: 120))
        assertEquals(rect.bottomRightCorner, start.bottomRightCorner)
    }

    @Test func testMinSizeClamp() {
        let shrunk = resizedRect(start, corner: ResizeCorner(movesLeftEdge: false, movesTopEdge: false), startMouse: CGPoint(x: 480, y: 380), mouse: CGPoint(x: -1000, y: -1000))
        assertEquals(shrunk.topLeftCorner, start.topLeftCorner)
        assertEquals(shrunk.size, minGrabResizeSize)

        let crossed = resizedRect(start, corner: ResizeCorner(movesLeftEdge: true, movesTopEdge: true), startMouse: CGPoint(x: 120, y: 120), mouse: CGPoint(x: 2000, y: 2000))
        assertEquals(crossed.bottomRightCorner, start.bottomRightCorner)
        assertEquals(crossed.size, minGrabResizeSize)
    }
}
