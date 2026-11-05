import AppKit
import Common

let tabBarHeightRange: ClosedRange<Int> = 1 ... 100
let tabBarFontSizeRange: ClosedRange<Int> = 1 ... 72
let tabBarGapRange: ClosedRange<Int> = 0 ... 100

/// `[tab-bar]`: a bar of tabs above every accordion container
struct TabBarConfig: Withable, Equatable, Sendable {
    var enabled: Bool = false
    var height: Int = 24
    var fontSize: Int = 12
    var showIcons: Bool = true
    /// Space between the bar and the windows of the accordion
    var gap: Int = 0
    var backgroundColor = ArgbColor(0xFF1E_1E2E)
    var activeColor = ArgbColor(0xFF89_B4FA)
    var inactiveColor = ArgbColor(0xFF31_3244)
    var textColor = ArgbColor(0xFFCD_D6F4)

    /// The space that the bar takes from the top of its accordion
    var reservedHeight: CGFloat { enabled ? CGFloat(height + gap) : 0 }
}

private func parseIntInRange(_ key: String, _ range: ClosedRange<Int>) -> @Sendable (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    { raw, backtrace in
        parseInt(raw, backtrace)
            .filter(.init(backtrace, "\(key) must be in [\(range.lowerBound), \(range.upperBound)] range")) { range.contains($0) }
    }
}

private let tabBarParserTable: [String: any ParserProtocol<TabBarConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "height": Parser(\.height, parseIntInRange("height", tabBarHeightRange)),
    "font-size": Parser(\.fontSize, parseIntInRange("font-size", tabBarFontSizeRange)),
    "show-icons": Parser(\.showIcons, parseBool),
    "gap": Parser(\.gap, parseIntInRange("gap", tabBarGapRange)),
    "background-color": Parser(\.backgroundColor, parseArgbColor),
    "active-color": Parser(\.activeColor, parseArgbColor),
    "inactive-color": Parser(\.inactiveColor, parseArgbColor),
    "text-color": Parser(\.textColor, parseArgbColor),
]

func parseTabBar(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> TabBarConfig {
    parseNonEmptyTable(raw, TabBarConfig(), tabBarParserTable, backtrace, &c)
}
