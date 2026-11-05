let deprecatedMouseGrabAnimationDurationKey = "animation-duration-ms"

private let mouseGrabParserTable: [String: any ParserProtocol<MouseGrabConfig>] = [
    "live-preview": Parser(\.livePreview, parseBool),
    deprecatedMouseGrabAnimationDurationKey: Parser(\._animationDurationMs) { raw, backtrace in
        parseAnimationDurationMs(raw, backtrace, key: deprecatedMouseGrabAnimationDurationKey).map(Optional.some)
    },
    "ignore-app-ids": Parser(\.ignoreAppIds, parseArrayOfStrings),
]

func parseMouseGrab(_ rawConfig: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> MouseGrabConfig {
    parseNonEmptyTable(rawConfig, MouseGrabConfig(), mouseGrabParserTable, backtrace, &c)
}
