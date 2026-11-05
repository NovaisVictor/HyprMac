import AppKit
import Common
import os

// The event tap swallows the mouse events of a grab, so the grabbed window's app never sees them.
// It lives on its own thread: a tap on the main thread would stall every click of the system whenever
// the main thread is busy, and macOS disables taps that are slow to respond.
// The same tap also detects modifier-only bindings (see ModifierTapDetector). It listens to the keyboard only
// while a mode has such a binding, and it never swallows keyboard events

private struct MouseGrabTapShared: Sendable {
    var snapshot: MouseGrabTapSnapshot = .disabled
    var state: MouseGrabTapState = .idle
    /// Consumed by the main thread in order. Consecutive drags are coalesced, only the latest point matters
    var pendingEvents: [MouseGrabTapEvent] = []
    var isDrainScheduled = false
}

private let tapShared = OSAllocatedUnfairLock(initialState: MouseGrabTapShared())
private let grabbedNativeWindowId = OSAllocatedUnfairLock<UInt32?>(initialState: nil)
private let modifierTapDetector = OSAllocatedUnfairLock(initialState: ModifierTapDetector())

/// Lets AX observers ignore the move/resize notifications caused by the grab itself, before any MainActor hop
func isGrabbedWithMouse(nativeWindowId: UInt32) -> Bool {
    grabbedNativeWindowId.withLock { $0 == nativeWindowId }
}

func setGrabbedWithMouseNativeWindowId(_ nativeWindowId: UInt32?) {
    grabbedNativeWindowId.withLock { $0 = nativeWindowId }
}

/// Must be called whenever the inputs of the snapshot change: the mode, the config, `hyprmac enable`, and the frontmost app
@MainActor func syncMouseGrabTapSnapshot(mode: String?) {
    let mouseBindings = mode.flatMap { config.modes[$0] }?.mouseBindings ?? [:]
    let snapshot = MouseGrabTapSnapshot(
        isEnabled: TrayMenuModel.shared.isEnabled,
        // Sorted, because the first of the equally specific matching triggers wins
        triggers: mouseBindings.values.sorted { $0.descriptionWithKeyCode < $1.descriptionWithKeyCode }.map(\.trigger),
        // The frontmost app and not the app under the cursor: the frontmost app is known from the activation notifications,
        // while the app under the cursor would need a window list query or AX in the tap, and the tap must stay fast
        isFrontmostAppIgnored: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            .map(config.mouseGrab.ignoreAppIds.contains) ?? false,
    )
    tapShared.withLock { $0.snapshot = snapshot }
}

/// Call only when the button is known to be physically released, otherwise the rest of the gesture would leak
/// to the app under the cursor. A grab of another button, started in the meantime, stays untouched
func resetMouseGrabTapState(ifGrabbing button: MouseButton) {
    tapShared.withLock {
        if $0.state == .grabbing(button) { $0.state = .idle }
    }
}

func takePendingMouseGrabTapEvents() -> [MouseGrabTapEvent] {
    tapShared.withLock { shared in
        let events = shared.pendingEvents
        shared.pendingEvents = []
        shared.isDrainScheduled = false
        return events
    }
}

/// Without modifier-only bindings, only the mouse buttons: listening to the keyboard may need the Input Monitoring permission
func inputTapEventMask(listensToKeys: Bool) -> CGEventMask {
    let mouseTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseDragged, .leftMouseUp,
        .rightMouseDown, .rightMouseDragged, .rightMouseUp,
        .otherMouseDown, .otherMouseDragged, .otherMouseUp,
    ]
    // keyDown and scrollWheel only cancel a modifier tap, e.g. cmd-c or cmd-scroll to zoom
    let keyTypes: [CGEventType] = listensToKeys ? [.flagsChanged, .keyDown, .scrollWheel] : []
    return (mouseTypes + keyTypes).reduce(0) { $0 | (1 << $1.rawValue) }
}

/// Call when one of our hotkeys fires, the tap might not see the key press of a Carbon hotkey
func spoilModifierTap() {
    _ = modifierTapDetector.withLock { $0.handle(.other, now: DispatchTime.now().uptimeNanoseconds) }
}

private func feedModifierTapDetector(_ input: ModifierTapInput) {
    let now = DispatchTime.now().uptimeNanoseconds
    guard let key = modifierTapDetector.withLock({ $0.handle(input, now: now) }) else { return }
    Task.startUnstructured { @MainActor in modifierTapDispatcher.tapped(key) }
}

/// Owned by the tap thread. Gives the callback access to its own tap, to re-enable it
private final class MouseGrabTapPort {
    var port: CFMachPort? = nil
    let listensToKeys: Bool

    init(listensToKeys: Bool) {
        self.listensToKeys = listensToKeys
    }
}

private func mouseGrabTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
    if unsafe userInfo.map({ unsafe Unmanaged<MouseGrabTapPort>.fromOpaque($0).takeUnretainedValue().listensToKeys }) == true {
        switch type {
            case .flagsChanged:
                feedModifierTapDetector(.flagsChanged(event.flags))
                return unsafe Unmanaged.passUnretained(event)
            case .keyDown, .scrollWheel:
                feedModifierTapDetector(.other)
                return unsafe Unmanaged.passUnretained(event)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                feedModifierTapDetector(.other) // The mouse grab below handles the press as usual
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                feedModifierTapDetector(.tapDisabled)
            default:
                break
        }
    }
    let input: MouseInput
    switch type {
        case .leftMouseDown: input = .down(.left)
        case .leftMouseDragged: input = .dragged(.left)
        case .leftMouseUp: input = .up(.left)
        case .rightMouseDown: input = .down(.right)
        case .rightMouseDragged: input = .dragged(.right)
        case .rightMouseUp: input = .up(.right)
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            // Buttons 3 and above (back/forward) aren't bindable
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else { return unsafe Unmanaged.passUnretained(event) }
            input = switch type {
                case .otherMouseDown: .down(.middle)
                case .otherMouseDragged: .dragged(.middle)
                default: .up(.middle)
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = unsafe userInfo.flatMap({ unsafe Unmanaged<MouseGrabTapPort>.fromOpaque($0).takeUnretainedValue().port }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            input = .tapDisabled
        default:
            return unsafe Unmanaged.passUnretained(event)
    }
    let point = event.location
    let flags = event.flags
    let (swallow, shouldScheduleDrain) = tapShared.withLock { shared -> (Bool, Bool) in
        let result = classifyMouseInput(input, flags: flags, point: point, state: shared.state, snapshot: shared.snapshot)
        shared.state = result.newState
        guard let event = result.event else { return (result.swallow, false) }
        if case .drag = event, case .drag = shared.pendingEvents.last {
            shared.pendingEvents[shared.pendingEvents.count - 1] = event
        } else {
            shared.pendingEvents.append(event)
        }
        let shouldScheduleDrain = !shared.isDrainScheduled
        shared.isDrainScheduled = true
        return (result.swallow, shouldScheduleDrain)
    }
    if shouldScheduleDrain {
        Task.startUnstructured { @MainActor in drainMouseGrabTapEvents() }
    }
    return swallow ? nil : unsafe Unmanaged.passUnretained(event)
}

/// What the running tap was created for. A change restarts the tap
struct InputTapKind: Equatable, Sendable {
    let listensToKeys: Bool
    /// Granting the Input Monitoring permission later restarts the tap, in case macOS filters the keyboard events
    /// of a tap created without it
    // periphery:ignore - read only through Equatable, which restarts the tap when it changes
    let hadListenEventAccess: Bool
}

/// nil when no tap is needed
@MainActor func desiredInputTapKind(
    isMouseGrabNeeded: Bool,
    isModifierTapNeeded: Bool,
    didKeyTapCreationFail: Bool,
    hasListenEventAccess: @MainActor () -> Bool,
) -> InputTapKind? {
    // A failed keyboard tap must not take the mouse bindings down with it
    let listensToKeys = isModifierTapNeeded && !didKeyTapCreationFail
    guard listensToKeys || isMouseGrabNeeded else { return nil }
    // The permission is checked only when it's needed, users without modifier-only bindings are never asked
    return InputTapKind(listensToKeys: listensToKeys, hadListenEventAccess: listensToKeys && hasListenEventAccess())
}

@MainActor private var tapThread: Thread? = nil
@MainActor private var tapKind: InputTapKind? = nil
@MainActor private var tapGeneration = 0
@MainActor private var axTrustPollTask: Task<(), any Error>? = nil
@MainActor private var didReportTapCreationFailure = false
@MainActor private var didReportKeyTapCreationFailure = false
@MainActor private var isMouseGrabTapNeeded = false
@MainActor private var isModifierTapNeeded = false
/// Reset by a config reload: that's when the user is likely to retry after fixing the permission
@MainActor private var didKeyTapCreationFail = false

/// The tap exists only while at least one mode has a mouse binding or a modifier-only binding,
/// users without them get no tap at all
@MainActor func syncMouseGrabTap(_ config: Config) {
    isMouseGrabTapNeeded = !serverArgs.isReadOnly && config.modes.values.contains { !$0.mouseBindings.isEmpty }
    isModifierTapNeeded = !serverArgs.isReadOnly && config.modes.values.contains { !$0.modifierTapBindings.isEmpty }
    didKeyTapCreationFail = false
    if isMouseGrabTapNeeded || isModifierTapNeeded {
        if axTrustPollTask == nil {
            axTrustPollTask = Task.startUnstructured { @MainActor in try await keepMouseGrabTapInSyncWithAxTrust() }
        } else {
            syncMouseGrabTapWithAxTrust() // A config change mustn't wait for the next poll
        }
    } else {
        axTrustPollTask?.cancel()
        axTrustPollTask = nil
        stopMouseGrabTap()
    }
}

/// An active tap of a process that lost the Accessibility permission can freeze the input of the whole system.
/// The same poll picks up the Input Monitoring permission, so the modifier-only bindings need no timer of their own
@MainActor private func keepMouseGrabTapInSyncWithAxTrust() async throws {
    while true {
        try checkCancellation()
        syncMouseGrabTapWithAxTrust()
        try await Task.sleep(for: .seconds(2))
    }
}

@MainActor private func syncMouseGrabTapWithAxTrust() {
    guard AXIsProcessTrusted() else {
        if tapThread != nil {
            cancelMouseGrab()
            stopMouseGrabTap()
        }
        return
    }
    let kind = desiredInputTapKind(
        isMouseGrabNeeded: isMouseGrabTapNeeded,
        isModifierTapNeeded: isModifierTapNeeded,
        didKeyTapCreationFail: didKeyTapCreationFail,
        hasListenEventAccess: listenEventAccessGate.hasAccess,
    )
    if tapThread != nil && tapKind != kind {
        cancelMouseGrab()
        stopMouseGrabTap()
    }
    if tapThread == nil, let kind { startMouseGrabTap(kind) }
}

@MainActor private func startMouseGrabTap(_ kind: InputTapKind) {
    tapGeneration += 1
    let generation = tapGeneration
    let listensToKeys = kind.listensToKeys
    let thread = Thread {
        let portBox = MouseGrabTapPort(listensToKeys: listensToKeys)
        guard let port = unsafe CGEvent.tapCreate(
                  tap: .cgSessionEventTap,
                  place: .headInsertEventTap,
                  options: .defaultTap,
                  eventsOfInterest: inputTapEventMask(listensToKeys: listensToKeys),
                  callback: mouseGrabTapCallback,
                  userInfo: unsafe Unmanaged.passUnretained(portBox).toOpaque(),
              ),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else {
            Task.startUnstructured { @MainActor in onMouseGrabTapCreationFailed(generation, listensToKeys: listensToKeys) }
            return
        }
        portBox.port = port
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()

        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CFMachPortInvalidate(port)
        withExtendedLifetime(portBox) {}
    }
    thread.name = "MouseGrabTapThread"
    thread.start()
    tapThread = thread
    tapKind = kind
}

@MainActor private func onMouseGrabTapCreationFailed(_ generation: Int, listensToKeys: Bool) {
    guard generation == tapGeneration else { return }
    tapThread = nil
    tapKind = nil
    if listensToKeys {
        didKeyTapCreationFail = true
        syncMouseGrabTapWithAxTrust() // Falls back to the mouse-only tap right away
        if didReportKeyTapCreationFailure { return }
        didReportKeyTapCreationFailure = true
        MessageModel.shared.message = Message(
            description: "HyprMac Modifier-Only Bindings",
            body: """
                Modifier-only bindings (e.g. 'cmd = { run = ..., on = 'release' }') don't work: macOS refused to let HyprMac listen to the keyboard.
                Make sure that HyprMac is allowed in System Settings -> Privacy & Security -> Input Monitoring and Accessibility, then reload the config.
                Mouse bindings are not affected.
                """,
            containsWarnings: false,
        )
        return
    }
    // The poll retries
    if didReportTapCreationFailure { return }
    didReportTapCreationFailure = true
    MessageModel.shared.message = Message(
        description: "HyprMac Mouse Bindings",
        body: """
            Mouse bindings don't work: macOS refused to let HyprMac listen to mouse events.
            Make sure that HyprMac is allowed in System Settings -> Privacy & Security -> Accessibility.
            HyprMac keeps retrying in the background.
            """,
        containsWarnings: false,
    )
}

@MainActor private func stopMouseGrabTap() {
    guard let thread = tapThread else { return }
    tapThread = nil
    tapKind = nil
    tapGeneration += 1
    thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
    tapShared.withLock { $0.state = .idle }
    // The old tap might have missed events, e.g. the key press that would spoil an armed tap
    modifierTapDetector.withLock { $0 = ModifierTapDetector() }
}
