public struct PreselectCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .preselect,
        help: preselect_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [newMandatoryPosArgParser(\.arg, parsePreselectArg, placeholder: PreselectArg.unionLiteral)],
    )

    public var arg: Lateinit<PreselectArg> = .uninitialized

    public enum PreselectArg: String, CaseIterable, Sendable {
        case left, down, up, right, cancel

        public var direction: CardinalDirection? {
            switch self {
                case .left: .left
                case .down: .down
                case .up: .up
                case .right: .right
                case .cancel: nil
            }
        }
    }
}

func parsePreselectCmdArgs(_ args: StrArrSlice) -> ParsedCmd<PreselectCmdArgs> {
    parseSpecificCmdArgs(PreselectCmdArgs(rawArgs: args), args)
}

private func parsePreselectArg(i: PosArgParserInput) -> ParsedCliArgs<PreselectCmdArgs.PreselectArg> {
    .init(parseEnum(i.arg, PreselectCmdArgs.PreselectArg.self), advanceBy: 1)
}
