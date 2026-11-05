public struct TreeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .tree,
        help: tree_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
            "--focused": trueBoolFlag(\.focused),
            "--all": trueBoolFlag(\.all),
            "--json": trueBoolFlag(\.json),
        ],
        posArgs: [],
        conflictingFlags: [
            ["--all", "--focused", "--workspace"],
        ],
    )

    public var focused: Bool = false
    public var all: Bool = false
    public var json: Bool = false
}

func parseTreeCmdArgs(_ args: StrArrSlice) -> ParsedCmd<TreeCmdArgs> {
    parseSpecificCmdArgs(TreeCmdArgs(rawArgs: args), args)
        .filter("Mandatory option is not specified (--workspace|--focused|--all)") { raw in
            raw.focused || raw.all || raw.workspaceName != nil
        }
}
