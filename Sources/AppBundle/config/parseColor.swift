import AppKit
import Common

/// A color written as `0xAARRGGBB`, the notation of JankyBorders and sketchybar. Shared by `[borders]` and `[tab-bar]`
struct ArgbColor: Equatable, Sendable, CustomStringConvertible {
    let argb: UInt32

    init(argb: UInt32) { self.argb = argb }
    init(_ argb: UInt32) { self.argb = argb }

    var alpha: CGFloat { component(shift: 24) }
    var red: CGFloat { component(shift: 16) }
    var green: CGFloat { component(shift: 8) }
    var blue: CGFloat { component(shift: 0) }

    var hexDescription: String {
        let hex = String(argb, radix: 16)
        return "0x" + String(repeating: "0", count: 8 - hex.count) + hex
    }
    var description: String { hexDescription }

    private func component(shift: UInt32) -> CGFloat { CGFloat((argb >> shift) & 0xFF) / 255 }
}

/// Parses `0xAARRGGBB`. The alpha is mandatory: `0xRRGGBB` is rejected rather than guessed
func parseArgbColor(_ raw: String) -> ArgbColor? {
    guard raw.count == 10, raw.lowercased().hasPrefix("0x") else { return nil }
    let hex = raw.dropFirst(2)
    guard hex.allSatisfy(\.isHexDigit) else { return nil }
    return UInt32(hex, radix: 16).map(ArgbColor.init(argb:))
}

/// Accepts the quoted `'0xAARRGGBB'` and the bare TOML hex integer `0xAARRGGBB`
func parseArgbColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<ArgbColor> {
    let error = ConfigParseDiagnostic(backtrace, "Can't parse color '\(raw.colorDescription)'. Expected format: '0xAARRGGBB' (alpha, red, green, blue)")
    switch raw {
        case .string(let string):
            return parseArgbColor(string).toResult(error)
        case .int(let int):
            return UInt32(exactly: int).map(ArgbColor.init(argb:)).toResult(error)
        default:
            return .failure(expectedActualTypeDiagnostic(expected: [.string, .int], actual: raw.tomlType, backtrace))
    }
}

extension OrderedJson {
    fileprivate var colorDescription: String {
        switch self {
            case .string(let string): string
            case .int(let int): String(int)
            default: String(describing: self)
        }
    }
}
