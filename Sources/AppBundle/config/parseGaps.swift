import Common

struct Gaps: Withable, Equatable, Sendable {
    var inner: Inner
    var outer: Outer
    /// When a workspace has a single tiling window, its gaps resolve to zero
    var smart: DynamicConfigValue<Bool> = .constant(false)

    static let zero = Gaps(inner: .zero, outer: .zero)

    struct Inner: Withable, Equatable, Sendable {
        var vertical: DynamicConfigValue<Int>
        var horizontal: DynamicConfigValue<Int>

        static let zero = Inner(vertical: 0, horizontal: 0)

        init(vertical: Int, horizontal: Int) {
            self.vertical = .constant(vertical)
            self.horizontal = .constant(horizontal)
        }

        init(vertical: DynamicConfigValue<Int>, horizontal: DynamicConfigValue<Int>) {
            self.vertical = vertical
            self.horizontal = horizontal
        }
    }

    struct Outer: Withable, Equatable, Sendable {
        var left: DynamicConfigValue<Int>
        var bottom: DynamicConfigValue<Int>
        var top: DynamicConfigValue<Int>
        var right: DynamicConfigValue<Int>

        static let zero = Outer(left: 0, bottom: 0, top: 0, right: 0)

        init(left: Int, bottom: Int, top: Int, right: Int) {
            self.left = .constant(left)
            self.bottom = .constant(bottom)
            self.top = .constant(top)
            self.right = .constant(right)
        }

        init(left: DynamicConfigValue<Int>, bottom: DynamicConfigValue<Int>, top: DynamicConfigValue<Int>, right: DynamicConfigValue<Int>) {
            self.left = left
            self.bottom = bottom
            self.top = top
            self.right = right
        }
    }
}

/// A partial ``Gaps``, used by the workspace rules. The unset values inherit the global gaps
struct GapsOverride: Withable, Equatable, Sendable {
    var inner: Inner = Inner()
    var outer: Outer = Outer()

    struct Inner: Withable, Equatable, Sendable {
        var vertical: DynamicConfigValue<Int>? = nil
        var horizontal: DynamicConfigValue<Int>? = nil
    }

    struct Outer: Withable, Equatable, Sendable {
        var left: DynamicConfigValue<Int>? = nil
        var bottom: DynamicConfigValue<Int>? = nil
        var top: DynamicConfigValue<Int>? = nil
        var right: DynamicConfigValue<Int>? = nil
    }

    func applied(to gaps: Gaps) -> Gaps {
        // Start from the global gaps, so that the options a workspace rule can't override (e.g. `smart`) are kept
        var result = gaps
        result.inner = .init(
            vertical: inner.vertical ?? gaps.inner.vertical,
            horizontal: inner.horizontal ?? gaps.inner.horizontal,
        )
        result.outer = .init(
            left: outer.left ?? gaps.outer.left,
            bottom: outer.bottom ?? gaps.outer.bottom,
            top: outer.top ?? gaps.outer.top,
            right: outer.right ?? gaps.outer.right,
        )
        return result
    }
}

struct ResolvedGaps {
    let inner: Inner
    let outer: Outer

    struct Inner {
        let vertical: Int
        let horizontal: Int

        func get(_ orientation: Orientation) -> Int {
            orientation == .h ? horizontal : vertical
        }
    }

    struct Outer {
        let left: Int
        let bottom: Int
        let top: Int
        let right: Int

        func pad(_ rect: Rect) -> Rect {
            Rect(
                topLeftX: rect.topLeftX + left.toDouble(),
                topLeftY: rect.topLeftY + top.toDouble(),
                width: rect.width - left.toDouble() - right.toDouble(),
                height: rect.height - top.toDouble() - bottom.toDouble(),
            )
        }
    }

    static let zero = ResolvedGaps(inner: .init(vertical: 0, horizontal: 0), outer: .init(left: 0, bottom: 0, top: 0, right: 0))

    private init(inner: Inner, outer: Outer) {
        self.inner = inner
        self.outer = outer
    }

    /// The gaps that the tiling layout of the workspace uses. Unlike ``init(gaps:monitor:)``, it takes `smart` into account
    @MainActor init(gaps: Gaps, workspace: Workspace) {
        let monitor = workspace.workspaceMonitorInfo
        if gaps.smart.getValue(for: monitor) && workspace.rootTilingContainer.allInhabitedLeafWindowsRecursive.count == 1 {
            self = .zero
        } else {
            self.init(gaps: gaps, monitor: monitor)
        }
    }

    @MainActor init(gaps: Gaps, monitor: any MonitorInfo) {
        inner = .init(
            vertical: gaps.inner.vertical.getValue(for: monitor),
            horizontal: gaps.inner.horizontal.getValue(for: monitor),
        )

        outer = .init(
            left: gaps.outer.left.getValue(for: monitor),
            bottom: gaps.outer.bottom.getValue(for: monitor),
            top: gaps.outer.top.getValue(for: monitor),
            right: gaps.outer.right.getValue(for: monitor),
        )
    }
}

private let gapsParser: [String: any ParserProtocol<Gaps>] = [
    "inner": Parser(\.inner, parseInner),
    "outer": Parser(\.outer, parseOuter),
    "smart": Parser(\.smart, parseBoolDynamicValue),
]

private let innerParser: [String: any ParserProtocol<Gaps.Inner>] = [
    "vertical": Parser(\.vertical, parseIntDynamicValue),
    "horizontal": Parser(\.horizontal, parseIntDynamicValue),
]

private let outerParser: [String: any ParserProtocol<Gaps.Outer>] = [
    "left": Parser(\.left, parseIntDynamicValue),
    "bottom": Parser(\.bottom, parseIntDynamicValue),
    "top": Parser(\.top, parseIntDynamicValue),
    "right": Parser(\.right, parseIntDynamicValue),
]

private let gapsOverrideParser: [String: any ParserProtocol<GapsOverride>] = [
    "inner": Parser(\.inner, parseInnerOverride),
    "outer": Parser(\.outer, parseOuterOverride),
]

private let innerOverrideParser: [String: any ParserProtocol<GapsOverride.Inner>] = [
    "vertical": Parser(\.vertical, parseOptionalIntDynamicValue),
    "horizontal": Parser(\.horizontal, parseOptionalIntDynamicValue),
]

private let outerOverrideParser: [String: any ParserProtocol<GapsOverride.Outer>] = [
    "left": Parser(\.left, parseOptionalIntDynamicValue),
    "bottom": Parser(\.bottom, parseOptionalIntDynamicValue),
    "top": Parser(\.top, parseOptionalIntDynamicValue),
    "right": Parser(\.right, parseOptionalIntDynamicValue),
]

private func parseOptionalIntDynamicValue(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> DynamicConfigValue<Int>? {
    parseIntDynamicValue(raw, backtrace, &c)
}

private func parseIntDynamicValue(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> DynamicConfigValue<Int> {
    parseDynamicValue(raw, ofType: Int.self, 0, backtrace, &c)
}

private func parseBoolDynamicValue(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> DynamicConfigValue<Bool> {
    parseDynamicValue(raw, ofType: Bool.self, false, backtrace, &c)
}

func parseGaps(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Gaps {
    parseNonEmptyTable(raw, .zero, gapsParser, backtrace, &c)
}

func parseInner(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Gaps.Inner {
    parseNonEmptyTable(raw, Gaps.Inner.zero, innerParser, backtrace, &c)
}

func parseOuter(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Gaps.Outer {
    parseNonEmptyTable(raw, Gaps.Outer.zero, outerParser, backtrace, &c)
}

func parseGapsOverride(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> GapsOverride {
    parseNonEmptyTable(raw, GapsOverride(), gapsOverrideParser, backtrace, &c)
}

private func parseInnerOverride(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> GapsOverride.Inner {
    parseNonEmptyTable(raw, GapsOverride.Inner(), innerOverrideParser, backtrace, &c)
}

private func parseOuterOverride(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> GapsOverride.Outer {
    parseNonEmptyTable(raw, GapsOverride.Outer(), outerOverrideParser, backtrace, &c)
}
