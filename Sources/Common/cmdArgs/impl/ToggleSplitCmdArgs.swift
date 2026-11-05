public struct ToggleSplitCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .toggleSplit,
        help: toggle_split_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [],
    )
}

func parseToggleSplitCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ToggleSplitCmdArgs> {
    parseSpecificCmdArgs(ToggleSplitCmdArgs(rawArgs: args), args)
}
