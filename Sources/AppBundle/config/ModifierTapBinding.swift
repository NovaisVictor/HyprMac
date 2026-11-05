import AppKit
import Common

/// A binding of a bare modifier, e.g. `cmd = { run = 'mode launcher', on = 'release' }`. It runs when the modifier is
/// pressed and released alone. Carbon hotkeys can't register a bare modifier, so these are detected by the event tap.
/// See `ModifierTapDetector`
struct ModifierTapBinding: Equatable, Sendable {
    let commands: Shell<any Command>
    /// `cmd`, or a side-specific variant like `rcmd`. There is a single spelling, so it's also the key in `Mode`
    let descriptionWithKeyNotation: String

    static func == (lhs: ModifierTapBinding, rhs: ModifierTapBinding) -> Bool {
        lhs.descriptionWithKeyNotation == rhs.descriptionWithKeyNotation && lhs.commands.strictEquals(rhs.commands)
    }
}

/// `cmd`, `alt`, `ctrl`, `shift` and their side-specific variants, e.g. `lcmd` and `rcmd`
let modifierTapNotations: Set<String> = Set(modifierSideMasks.flatMap { [$0.name, "l" + $0.name, "r" + $0.name] })

/// The side-specific binding wins over the generic one. A key of an unknown side triggers only the generic binding
func modifierTapBinding(for key: ModifierKey, in bindings: [String: ModifierTapBinding]) -> ModifierTapBinding? {
    key.side.flatMap { bindings[$0.notationPrefix + key.name] } ?? bindings[key.name]
}

private let modifierTapValueError = "Modifier-only bindings fire on release, use { run = ..., on = 'release' }"

/// nil if the binding is invalid. The errors are reported to `c`
func parseModifierTapBinding(
    _ raw: String,
    _ rawCommand: OrderedJson,
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext,
) -> ModifierTapBinding? {
    guard let table = rawCommand.asDictOrNil else {
        c.errors.append(.init(backtrace, modifierTapValueError))
        return nil
    }
    // Checked on the raw table, because even `repeat = false` suggests a misunderstanding: a tap can't be held
    if table["repeat"] != nil {
        c.errors.append(.init(backtrace + .key("repeat"), "Modifier-only bindings can't repeat"))
        return nil
    }
    let errorsBefore = c.errors.count
    let value = parseHotkeyBindingValue(rawCommand, backtrace, &c)
    if c.errors.count > errorsBefore { return nil }
    if value.trigger != .release {
        c.errors.append(.init(backtrace, modifierTapValueError))
        return nil
    }
    if let grabKind = value.commands.flatten().lazy.compactMap(\.grabKind).first {
        c.errors.append(.init(backtrace, grabCommandOutsideOfMouseBindingError(grabKind)))
        return nil
    }
    return ModifierTapBinding(commands: value.commands, descriptionWithKeyNotation: raw)
}
