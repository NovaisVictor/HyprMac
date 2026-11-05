public struct ScratchpadToggleCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .scratchpadToggle,
        help: scratchpad_toggle_help_generated,
        flags: [
            "--app-bundle-id": singleValueSubArgParser(\.appBundleId, "<app-bundle-id>", Result.success),
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [],
        conflictingFlags: [
            ["--app-bundle-id", "--window-id"],
        ],
    )

    public var appBundleId: String?
}

func parseScratchpadToggleCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ScratchpadToggleCmdArgs> {
    // The subject is mandatory on purpose: the HYPRMAC_WINDOW_ID/focus fallback that other commands use would make
    // the binding toggle whatever window happens to be focused instead of the dedicated scratchpad app
    parseSpecificCmdArgs(ScratchpadToggleCmdArgs(rawArgs: args), args)
        .filter("Mandatory option is not specified (--app-bundle-id|--window-id)") { $0.appBundleId != nil || $0.windowId != nil }
}
