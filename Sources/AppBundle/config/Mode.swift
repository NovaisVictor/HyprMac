import Common
import HotKey

struct Mode: Withable, Equatable, Sendable {
    var bindings: [String: HotkeyBinding]
    var mouseBindings: [String: MouseBinding] = [:]
    var modifierTapBindings: [String: ModifierTapBinding] = [:]

    static let zero = Mode(bindings: [:])
}

func parseModes(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext, _ mapping: [String: Key]) -> [String: Mode] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: Mode] = [:]
    for (key, value) in rawTable {
        result[key] = parseMode(value, backtrace + .key(key), &c, mapping, key)
    }
    if !result.keys.contains(mainModeId) {
        c.errors += [.init(backtrace, "Please specify '\(mainModeId)' mode")]
    }
    return result
}

func parseMode(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext, _ mapping: [String: Key], _ modeName: String) -> Mode {
    guard let rawTable: OrderedJson.JsonDict = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return .zero
    }

    if rawTable.isEmpty {
        c.errors.append(.init(backtrace, "empty table is not allowed here. Please use 'mode.\(modeName).binding = {}' instead"))
    }

    var result: Mode = .zero
    for (key, value) in rawTable {
        let backtrace = backtrace + .key(key)
        switch key {
            case "binding":
                (result.bindings, result.mouseBindings, result.modifierTapBindings) = parseBindings(value, backtrace, &c, mapping, modeName: modeName)
            default:
                c.errors += [unknownKeyDiagnostic(backtrace)]
        }
    }
    return result
}
