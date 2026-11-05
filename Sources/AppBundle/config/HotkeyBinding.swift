import AppKit
import Common
import Foundation
import HotKey

@MainActor private var hotkeys: [String: HotKey] = [:]

@MainActor func resetHotKeys() {
    // Explicitly unregister all hotkeys. We cannot always rely on destruction of the HotKey object to trigger
    // unregistration because we might be running inside a hotkey handler that is keeping its HotKey object alive.
    for (_, key) in hotkeys {
        key.isEnabled = false
    }
    hotkeys = [:]
    hotkeyDispatcher.cancel()
}

extension HotKey {
    var isEnabled: Bool {
        get { !isPaused }
        set {
            if isEnabled != newValue {
                isPaused = !newValue
            }
        }
    }
}

@MainActor var activeMode: String? = mainModeId
@MainActor func activateMode_nonCancellable(_ targetMode: String?) async {
    let targetBindings = targetMode.flatMap { config.modes[$0] }?.bindings ?? [:]
    if targetMode != activeMode {
        // The held key belongs to the old mode. Its key-up must not run a release binding of the new mode either
        hotkeyDispatcher.cancel()
    }
    for binding in targetBindings.values where !hotkeys.keys.contains(binding.descriptionWithKeyCode) {
        let key = binding.descriptionWithKeyCode
        // The HotKey object is shared by all modes that bind the same key, so the handlers resolve the binding of
        // the active mode on every event
        hotkeys[key] = HotKey(
            key: binding.keyCode,
            modifiers: binding.modifiers,
            keyDownHandler: {
                // In case the event tap didn't see the key press, a hotkey must not leave a modifier tap armed
                spoilModifierTap()
                hotkeyDispatcher.keyDown(key)
            },
            keyUpHandler: { hotkeyDispatcher.keyUp(key) },
        )
    }
    for (binding, key) in hotkeys {
        key.isEnabled = targetBindings.keys.contains(binding)
    }
    syncMouseGrabTapSnapshot(mode: targetMode)
    let oldMode = activeMode
    activeMode = targetMode
    if oldMode != targetMode {
        broadcastEvent(.modeChanged(mode: targetMode))
        _ = await config.onModeChanged.run(.defaultEnv, .emptyStdin)
    }
}

@MainActor let hotkeyDispatcher = HotkeyDispatcher(
    repeater: KeyRepeater(),
    // A safety net against a lost key-up, which would repeat forever. Only the modifiers can be checked: the state
    // of the other keys isn't available without the Input Monitoring permission
    isStillHeld: { NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: $0.modifiers) },
) { binding, mode in
    try await runBinding(binding.commands, notation: binding.descriptionWithKeyNotation, mode: mode)
}

/// Shared by keyboard and modifier-only bindings, so that both run in the same session and are reported the same way
@MainActor func runBinding(_ commands: Shell<any Command>, notation: String, mode: String) async throws {
    broadcastEvent(.bindingTriggered(mode: mode, binding: notation))
    try await runLightSession(.hotkeyBinding, .checkServerIsEnabledOrDie()) { () throws in
        _ = await commands.run(.defaultEnv, .emptyStdin)
    }
}

/// Decides what a hotkey press or release does, depending on the `on` and `repeat` options of the binding
@MainActor
final class HotkeyDispatcher {
    private let repeater: KeyRepeater
    private let isStillHeld: @MainActor (HotkeyBinding) -> Bool
    private let run: @MainActor (HotkeyBinding, _ mode: String) async throws -> Void
    /// Keys pressed while a mode was active. A release binding runs only if its key was pressed in the same mode,
    /// so that the key-up of a binding that switches modes doesn't trigger a release binding of the new mode
    private var pressedKeys: [String: String] = [:]

    init(
        repeater: KeyRepeater,
        isStillHeld: @escaping @MainActor (HotkeyBinding) -> Bool,
        run: @escaping @MainActor (HotkeyBinding, _ mode: String) async throws -> Void,
    ) {
        self.repeater = repeater
        self.isStillHeld = isStillHeld
        self.run = run
    }

    @discardableResult
    func keyDown(_ key: String) -> Task<Void, any Error>? {
        guard let mode = activeMode, let binding = config.modes[mode]?.bindings[key] else { return nil }
        pressedKeys[key] = mode
        switch binding.trigger {
            case .release:
                return nil
            case .press:
                if binding.repeats {
                    // Started before the first run, so that a key-up that arrives while the first run is still in
                    // progress stops the repeat
                    repeater.start(key: key) { [weak self] in
                        guard let self else { return }
                        guard isStillHeld(binding) else {
                            repeater.stop(key: key)
                            return
                        }
                        do {
                            try await run(binding, mode)
                        } catch {
                            // runLightSession throws only when the session can't run (e.g. it's cancelled), so
                            // the next steps would fail the same way
                            repeater.stop(key: key)
                        }
                    }
                }
                let run = run
                return Task.startUnstructured { try await run(binding, mode) }
        }
    }

    @discardableResult
    func keyUp(_ key: String) -> Task<Void, any Error>? {
        repeater.stop(key: key)
        guard let pressedMode = pressedKeys.removeValue(forKey: key), pressedMode == activeMode,
              let binding = config.modes[pressedMode]?.bindings[key], binding.trigger == .release
        else { return nil }
        let run = run
        return Task.startUnstructured { try await run(binding, pressedMode) }
    }

    func cancel() {
        repeater.cancel()
        pressedKeys = [:]
    }
}

enum HotkeyTrigger: String, Equatable, Sendable {
    case press, release
}

struct HotkeyBinding: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    let keyCode: Key
    let commands: Shell<any Command>
    let trigger: HotkeyTrigger
    /// Only with `trigger == .press`
    let repeats: Bool
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String

    init(
        _ modifiers: NSEvent.ModifierFlags,
        _ keyCode: Key,
        _ commands: Shell<any Command>,
        trigger: HotkeyTrigger = .press,
        repeats: Bool = false,
        descriptionWithKeyNotation: String,
    ) {
        check(!repeats || trigger == .press, "Only press bindings can repeat")
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.commands = commands
        self.trigger = trigger
        self.repeats = repeats
        self.descriptionWithKeyCode = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString() + "-" + keyCode.toString()
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    static func == (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.modifiers == rhs.modifiers &&
            lhs.keyCode == rhs.keyCode &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            lhs.trigger == rhs.trigger &&
            lhs.repeats == rhs.repeats &&
            lhs.commands.strictEquals(rhs.commands)
    }
}

func parseBindings(
    _ raw: OrderedJson,
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext,
    _ mapping: [String: Key],
    modeName: String,
) -> (keyboard: [String: HotkeyBinding], mouse: [String: MouseBinding], modifierTap: [String: ModifierTapBinding]) {
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return ([:], [:], [:])
    }
    var result: [String: HotkeyBinding] = [:]
    var mouseResult: [String: MouseBinding] = [:]
    var modifierTapResult: [String: ModifierTapBinding] = [:]
    for (binding, rawCommand): (String, OrderedJson) in rawTable {
        let backtrace = backtrace + .key(binding)
        if modifierTapNotations.contains(binding) {
            // TOML keys are unique and each notation has a single spelling, so there is no redeclaration to check
            modifierTapResult[binding] = parseModifierTapBinding(binding, rawCommand, backtrace, &c)
            continue
        }
        if let button = mouseButton(ofBindingNotation: binding) {
            if let mouseBinding = parseMouseBinding(binding, button, rawCommand, backtrace, &c, modeName: modeName) {
                if mouseResult.keys.contains(mouseBinding.descriptionWithKeyCode) {
                    c.errors.append(.init(backtrace, "'\(mouseBinding.descriptionWithKeyCode)' Binding redeclaration"))
                }
                mouseResult[mouseBinding.descriptionWithKeyCode] = mouseBinding
            }
            continue
        }
        let binding = parseBinding(binding, backtrace, mapping)
            .map { modifiers, key -> HotkeyBinding in
                let value = parseHotkeyBindingValue(rawCommand, backtrace, &c)
                if let grabKind = value.commands.flatten().lazy.compactMap(\.grabKind).first {
                    c.errors.append(.init(backtrace, grabCommandOutsideOfMouseBindingError(grabKind)))
                }
                return HotkeyBinding(
                    modifiers,
                    key,
                    value.commands,
                    trigger: value.trigger,
                    repeats: value.repeats,
                    descriptionWithKeyNotation: binding,
                )
            }
            .getOrNil(appendErrorTo: &c.errors)
        if let binding {
            if result.keys.contains(binding.descriptionWithKeyCode) {
                c.errors.append(.init(backtrace, "'\(binding.descriptionWithKeyCode)' Binding redeclaration"))
            }
            result[binding.descriptionWithKeyCode] = binding
        }
    }
    return (result, mouseResult, modifierTapResult)
}

private struct HotkeyBindingValue: Withable {
    var commands: Shell<any Command>? = nil
    var trigger: HotkeyTrigger = .press
    var repeats: Bool = false
}

private let hotkeyBindingValueParser: [String: any ParserProtocol<HotkeyBindingValue>] = [
    "run": Parser(\.commands) { raw, backtrace, c -> Shell<any Command>? in parseShellOfCommandsForConfig(raw, backtrace, &c) },
    "on": Parser(\.trigger, parseHotkeyTrigger),
    "repeat": Parser(\.repeats, parseBool),
]

/// The value is either the commands (a string or an array), or an inline table with the commands in `run`
func parseHotkeyBindingValue(
    _ raw: OrderedJson,
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext,
) -> (commands: Shell<any Command>, trigger: HotkeyTrigger, repeats: Bool) {
    guard let table = raw.asDictOrNil else {
        if raw.asStringOrNil == nil && raw.asArrayOrNil == nil {
            c.errors.append(expectedActualTypeDiagnostic(expected: [.string, .array, .table], actual: raw.tomlType, backtrace))
            return (.empty, .press, false)
        }
        return (parseShellOfCommandsForConfig(raw, backtrace, &c), .press, false)
    }
    let value = table.parseTable(HotkeyBindingValue(), hotkeyBindingValueParser, backtrace, &c, allowEmpty: false)
    guard let commands = value.commands else {
        c.errors.append(.init(backtrace, "'run' is mandatory"))
        return (.empty, .press, false)
    }
    if value.repeats && value.trigger == .release {
        c.errors.append(.init(backtrace + .key("repeat"), "'repeat = true' is incompatible with 'on = \'release\''"))
        return (commands, .release, false)
    }
    return (commands, value.trigger, value.repeats)
}

private func parseHotkeyTrigger(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<HotkeyTrigger> {
    parseString(raw, backtrace).flatMap {
        HotkeyTrigger(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse '\($0)'. Possible values: press, release"))
    }
}

func parseBinding(_ raw: String, _ backtrace: ConfigBacktrace, _ mapping: [String: Key]) -> ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, Key)> {
    let rawKeys = raw.split(separator: "-")
    let modifiers: ResOrConfigParseDiagnostic<NSEvent.ModifierFlags> = rawKeys.dropLast()
        .mapAllOrFailure {
            modifiersMap[String($0)].toResult(.init(backtrace, "Can't parse modifiers in '\(raw)' binding"))
        }
        .map { NSEvent.ModifierFlags($0) }
    let key: ResOrConfigParseDiagnostic<Key> = rawKeys.last.flatMap { mapping[String($0)] }
        .toResult(.init(backtrace, ["Can't parse the key in '\(raw)' binding", mouseButtonCaseMismatchHint(raw)].compactMap { $0 }.joined(separator: ". ")))
    return modifiers.flatMap { modifiers -> ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, Key)> in
        key.flatMap { key -> ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, Key)> in
            .success((modifiers, key))
        }
    }
}
