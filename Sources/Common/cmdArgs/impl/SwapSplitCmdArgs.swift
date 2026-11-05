public struct SwapSplitCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .swapSplit,
        help: swap_split_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [],
    )
}

func parseSwapSplitCmdArgs(_ args: StrArrSlice) -> ParsedCmd<SwapSplitCmdArgs> {
    parseSpecificCmdArgs(SwapSplitCmdArgs(rawArgs: args), args)
}
