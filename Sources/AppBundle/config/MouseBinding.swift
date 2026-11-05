import AppKit
import Common

enum MouseButton: String, CaseIterable, Sendable {
    case left = "leftMouse"
    case right = "rightMouse"
    case middle = "middleMouse"
}

/// What a mouse binding does while its button is held. Kept separate from the command names, which are a public
/// contract that may still change upstream
enum GrabKind: Sendable {
    case move
    case resize

    var commandName: String {
        switch self {
            case .move: CmdKind.grabAndMove.rawValue
            case .resize: CmdKind.grabAndResize.rawValue
        }
    }
}

struct MouseBinding: Equatable, Sendable {
    /// Also contains the side-specific modifiers, e.g. `lalt` contributes `option`
    let modifiers: NSEvent.ModifierFlags
    /// The device dependent bits of the side-specific modifiers. See `modifierSideMasks`
    let sideSpecificModifiers: CGEventFlags
    let button: MouseButton
    let grabKind: GrabKind
    /// Kept for `hyprmac config` and `trigger-binding`. The grab itself never runs them
    let commands: Shell<any Command>
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String

    init(
        _ modifiers: NSEvent.ModifierFlags,
        sideSpecificModifiers: CGEventFlags,
        _ button: MouseButton,
        _ grabKind: GrabKind,
        _ commands: Shell<any Command>,
        descriptionWithKeyNotation: String,
    ) {
        self.modifiers = modifiers
        self.sideSpecificModifiers = sideSpecificModifiers
        self.button = button
        self.grabKind = grabKind
        self.commands = commands
        let modifiersDescription = mouseModifiersDescription(modifiers, sideSpecificModifiers: sideSpecificModifiers)
        self.descriptionWithKeyCode = modifiersDescription.isEmpty
            ? button.rawValue
            : modifiersDescription + "-" + button.rawValue
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    var trigger: MouseGrabTrigger {
        MouseGrabTrigger(modifiers: modifiers.asCgEventFlags, sideSpecificModifiers: sideSpecificModifiers, button: button, kind: grabKind)
    }

    static func == (lhs: MouseBinding, rhs: MouseBinding) -> Bool {
        lhs.modifiers == rhs.modifiers &&
            lhs.sideSpecificModifiers == rhs.sideSpecificModifiers &&
            lhs.button == rhs.button &&
            lhs.grabKind == rhs.grabKind &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            lhs.commands.strictEquals(rhs.commands)
    }
}

func grabCommandOutsideOfMouseBindingError(_ kind: GrabKind) -> String {
    "\(kind.commandName) can only be triggered by a mouse binding (e.g. alt-\(MouseButton.left.rawValue))"
}

extension Command {
    var grabKind: GrabKind? {
        switch self {
            case is GrabAndMoveCommand: .move
            case is GrabAndResizeCommand: .resize
            default: nil
        }
    }
}

func mouseButton(ofBindingNotation raw: String) -> MouseButton? {
    raw.split(separator: "-").last.flatMap { MouseButton(rawValue: String($0)) }
}

/// nil if the binding is invalid. The errors are reported to `c`
func parseMouseBinding(
    _ raw: String,
    _ button: MouseButton,
    _ rawCommand: OrderedJson,
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext,
    modeName: String,
) -> MouseBinding? {
    var modifiers = NSEvent.ModifierFlags()
    var genericModifiers = NSEvent.ModifierFlags()
    var sideSpecificModifiers: CGEventFlags = []
    for rawModifier in raw.split(separator: "-").dropLast().map(String.init) {
        if let modifier = modifiersMap[rawModifier] {
            modifiers.formUnion(modifier)
            genericModifiers.formUnion(modifier)
        } else if let (modifier, side) = sideSpecificModifiersMap[rawModifier] {
            modifiers.formUnion(modifier)
            sideSpecificModifiers.formUnion(side)
        } else {
            c.errors.append(.init(backtrace, "Can't parse modifiers in '\(raw)' binding"))
            return nil
        }
    }
    let sideSpecificGenericModifiers = NSEvent.ModifierFlags(sideSpecificModifiers: sideSpecificModifiers)
    if !genericModifiers.isDisjoint(with: sideSpecificGenericModifiers) {
        let conflicting = genericModifiers.intersection(sideSpecificGenericModifiers).toString()
        c.errors.append(.init(backtrace, "'\(raw)' binding combines '\(conflicting)' with its side-specific variant. " +
                "'\(conflicting)' already matches either side"))
        return nil
    }
    let errorsBefore = c.errors.count
    let commands = parseShellOfCommandsForConfig(rawCommand, backtrace, &c)
    if c.errors.count > errorsBefore { return nil }
    guard case .cmd(let command) = commands, let grabKind = command.grabKind else {
        c.errors.append(.init(backtrace, "Mouse bindings support only a single '\(GrabKind.move.commandName)' or '\(GrabKind.resize.commandName)' command"))
        return nil
    }
    if modifiers.isEmpty && modeName == mainModeId {
        c.errors.append(.init(backtrace, "'\(raw)' binding without modifiers would intercept every click in '\(mainModeId)' mode. " +
                "Add a modifier, e.g. 'alt-\(button.rawValue)'"))
        return nil
    }
    return MouseBinding(modifiers, sideSpecificModifiers: sideSpecificModifiers, button, grabKind, commands, descriptionWithKeyNotation: raw)
}

/// Mouse bindings only. Keyboard bindings are registered as Carbon hotkeys, which can't tell the sides apart
private let sideSpecificModifiersMap: [String: (NSEvent.ModifierFlags, CGEventFlags)] = Dictionary(
    uniqueKeysWithValues: modifierSideMasks.flatMap { masks in
        [("l" + masks.name, (masks.modifier, masks.left)), ("r" + masks.name, (masks.modifier, masks.right))]
    },
)

extension NSEvent.ModifierFlags {
    /// The modifiers whose side-specific variants are in `sideSpecificModifiers`
    fileprivate init(sideSpecificModifiers: CGEventFlags) {
        self.init()
        for masks in modifierSideMasks where !sideSpecificModifiers.isDisjoint(with: masks.bothSides) {
            formUnion(masks.modifier)
        }
    }
}

/// Normalized, so that the same binding written in a different order is a redeclaration
private func mouseModifiersDescription(_ modifiers: NSEvent.ModifierFlags, sideSpecificModifiers: CGEventFlags) -> String {
    var result: [String] = []
    for masks in modifierSideMasks where modifiers.contains(masks.modifier) {
        let isLeft = sideSpecificModifiers.contains(masks.left)
        let isRight = sideSpecificModifiers.contains(masks.right)
        if !isLeft && !isRight { result.append(masks.name) }
        if isLeft { result.append("l" + masks.name) }
        if isRight { result.append("r" + masks.name) }
    }
    return result.joined(separator: "-")
}

/// Helps with the most likely typo, since key notation is case sensitive
func mouseButtonCaseMismatchHint(_ rawBinding: String) -> String? {
    guard let rawKey = rawBinding.split(separator: "-").last.map(String.init) else { return nil }
    return MouseButton.allCases.first(where: { $0.rawValue.lowercased() == rawKey.lowercased() })
        .map { "Did you mean '\($0.rawValue)'?" }
}
