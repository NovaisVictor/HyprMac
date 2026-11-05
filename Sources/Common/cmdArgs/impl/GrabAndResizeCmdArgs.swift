public struct GrabAndResizeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .grabAndResize,
        help: grab_and_resize_help_generated,
        flags: [:],
        posArgs: [],
    )
}
