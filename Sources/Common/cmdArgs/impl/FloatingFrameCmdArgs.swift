public struct FloatingFrameCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .floatingFrame,
        help: floating_frame_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--center": trueBoolFlag(\.center),
            "--size": singleValueSubArgParser(\.size, "<width>x<height>", parseFloatingFrameSize),
            "--position": singleValueSubArgParser(\.position, "<x>,<y>", parseFloatingFramePosition),
        ],
        posArgs: [],
        conflictingFlags: [["--center", "--position"]],
    )

    public var center: Bool = false
    public var size: Size? = nil
    public var position: Position? = nil

    public init(rawArgs: [String], center: Bool = false, size: Size? = nil, position: Position? = nil) {
        self.commonState = .init(rawArgs.slice)
        self.center = center
        self.size = size
        self.position = position
    }

    public enum Length: Equatable, Sendable {
        case pixels(UInt)
        /// Percent of the reference rect dimension. 0...100
        case percent(UInt)
    }

    public struct Size: Equatable, Sendable {
        public let width: Length
        public let height: Length

        public init(width: Length, height: Length) {
            self.width = width
            self.height = height
        }
    }

    public struct Position: Equatable, Sendable {
        public let x: Length
        public let y: Length

        public init(x: Length, y: Length) {
            self.x = x
            self.y = y
        }
    }
}

func parseFloatingFrameCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FloatingFrameCmdArgs> {
    parseSpecificCmdArgs(FloatingFrameCmdArgs(rawArgs: args), args)
        .filter("At least one of --size, --position or --center is required") {
            $0.size != nil || $0.position != nil || $0.center
        }
}

private func parseFloatingFrameSize(_ raw: String) -> ResOrStr<FloatingFrameCmdArgs.Size> {
    let parts = raw.split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return .failure("Expected format: <width>x<height>") }
    return parseLength(String(parts[0]), allowZero: false).flatMap { width in
        parseLength(String(parts[1]), allowZero: false).map { height in .init(width: width, height: height) }
    }
}

private func parseFloatingFramePosition(_ raw: String) -> ResOrStr<FloatingFrameCmdArgs.Position> {
    let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return .failure("Expected format: <x>,<y>") }
    return parseLength(String(parts[0]), allowZero: true).flatMap { x in
        parseLength(String(parts[1]), allowZero: true).map { y in .init(x: x, y: y) }
    }
}

private func parseLength(_ raw: String, allowZero: Bool) -> ResOrStr<FloatingFrameCmdArgs.Length> {
    let isPercent = raw.hasSuffix("%")
    guard let number = UInt(isPercent ? String(raw.dropLast()) : raw) else {
        return .failure("'\(raw)' must be a non-negative integer, optionally followed by '%'")
    }
    if !allowZero && number == 0 {
        return .failure("'\(raw)' must be greater than zero")
    }
    if isPercent && number > 100 {
        return .failure("'\(raw)' must not exceed 100%")
    }
    return .success(isPercent ? .percent(number) : .pixels(number))
}
