public struct GrabAndMoveCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .grabAndMove,
        help: grab_and_move_help_generated,
        flags: [:],
        posArgs: [],
    )
}
