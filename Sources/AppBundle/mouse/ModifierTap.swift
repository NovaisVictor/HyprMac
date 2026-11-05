import AppKit
import Carbon
import Common

@MainActor let modifierTapDispatcher = ModifierTapDispatcher(
    // Secure input (e.g. a password field) hides the key presses from the event tap but not the modifiers,
    // so cmd-v into a password field would look like a tap of cmd
    isSecureInputEnabled: { IsSecureEventInputEnabled() },
) { binding, mode in
    try await runBinding(binding.commands, notation: binding.descriptionWithKeyNotation, mode: mode)
}

/// Runs the modifier-only binding of the active mode for a tapped modifier
@MainActor
final class ModifierTapDispatcher {
    private let isSecureInputEnabled: @MainActor () -> Bool
    private let run: @MainActor (ModifierTapBinding, _ mode: String) async throws -> Void

    init(
        isSecureInputEnabled: @escaping @MainActor () -> Bool,
        run: @escaping @MainActor (ModifierTapBinding, _ mode: String) async throws -> Void,
    ) {
        self.isSecureInputEnabled = isSecureInputEnabled
        self.run = run
    }

    /// `activeMode` is nil while HyprMac is disabled, so are the modifier-only bindings
    @discardableResult
    func tapped(_ key: ModifierKey) -> Task<Void, any Error>? {
        guard let mode = activeMode,
              let binding = config.modes[mode].flatMap({ modifierTapBinding(for: key, in: $0.modifierTapBindings) }),
              !isSecureInputEnabled()
        else { return nil }
        let run = run
        return Task.startUnstructured { try await run(binding, mode) }
    }
}

@MainActor let listenEventAccessGate = ListenEventAccessGate(
    preflight: { CGPreflightListenEventAccess() },
    request: { CGRequestListenEventAccess() },
    report: { MessageModel.shared.message = $0 },
)

/// The keyboard events of the tap likely need the Input Monitoring permission (kTCCServiceListenEvent).
/// The permission is requested once per launch: macOS shows its prompt only once anyway,
/// and the message tells where to grant it later
@MainActor
final class ListenEventAccessGate {
    private let preflight: @MainActor () -> Bool
    private let request: @MainActor () -> Bool
    private let report: @MainActor (Message) -> Void
    private var didRequest = false

    init(
        preflight: @escaping @MainActor () -> Bool,
        request: @escaping @MainActor () -> Bool,
        report: @escaping @MainActor (Message) -> Void,
    ) {
        self.preflight = preflight
        self.request = request
        self.report = report
    }

    func hasAccess() -> Bool {
        if preflight() { return true }
        if didRequest { return false }
        didRequest = true
        if request() { return true }
        report(listenEventAccessMessage)
        return false
    }
}

@MainActor let listenEventAccessMessage = Message(
    description: "HyprMac Modifier-Only Bindings",
    body: """
        Your config has modifier-only bindings (e.g. 'cmd = { run = ..., on = 'release' }').
        To tell a tap of 'cmd' alone from 'cmd-c', HyprMac needs to see the key presses.
        Allow HyprMac in System Settings -> Privacy & Security -> Input Monitoring.
        HyprMac picks the permission up within a few seconds. If the bindings still don't work, restart HyprMac.
        Without the permission, the other bindings keep working.
        """,
    containsWarnings: false,
)
