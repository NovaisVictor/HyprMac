import Common

private let workspaceRuleParser: [String: any ParserProtocol<WorkspaceRule>] = [
    "default-root-container-layout": Parser(\.defaultRootContainerLayout, optional(parseLayout)),
    "default-root-container-orientation": Parser(\.defaultRootContainerOrientation, optional(parseDefaultContainerOrientation)),
    "enable-normalization-flatten-containers": Parser(\.enableNormalizationFlattenContainers, optional(parseBool)),
    "enable-normalization-opposite-orientation-for-nested-containers":
        Parser(\.enableNormalizationOppositeOrientationForNestedContainers, optional(parseBool)),
    "new-window-placement": Parser(\.newWindowPlacement, optional(parseNewWindowPlacement)),
    "master-new-window": Parser(\.masterNewWindow, optional(parseMasterNewWindow)),
    "gaps": Parser(\.gaps, parseGapsOverride),
]

/// The workspaces don't have to exist, the same as in `workspace-to-monitor-force-assignment`
func parseWorkspaceRules(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: WorkspaceRule] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: WorkspaceRule] = [:]
    for (workspaceName, rawRule) in rawTable {
        result[workspaceName] = parseNonEmptyTable(rawRule, WorkspaceRule(), workspaceRuleParser, backtrace + .key(workspaceName), &c)
    }
    return result
}

private func optional<T>(
    _ parse: @escaping @Sendable (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<T>,
) -> @Sendable (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<T?> {
    { raw, backtrace in parse(raw, backtrace).map { $0 } }
}
