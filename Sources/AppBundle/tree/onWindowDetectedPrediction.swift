import Common

/// Where a newly detected window is bound to the tree
struct DetectedWindowPlacement: Equatable {
    var workspace: Workspace
    var kind: Kind

    enum Kind: Equatable {
        case floating
        /// Placed like any new tiling window (according to `new-window-placement`)
        case newTilingWindow
        /// That's where `move-node-to-workspace` puts tiling windows
        case appendedToRootTilingContainer
    }
}

/// The outcome of the leading on-window-detected callbacks, predicted before the window is bound to the tree.
///
/// Without the prediction, the window is tiled into the focused workspace first and only then moved by the callbacks.
/// The callbacks have suspension points, so a concurrent session can lay out the workspace in between:
/// the neighbours reflow, and the new window gets a tile it doesn't belong to.
/// With dwindle placement, the window also splits the most recent window of the focused workspace.
///
/// The callbacks still run as usual afterward. The predicted placement commands become no-ops.
struct OnWindowDetectedPrediction {
    let callbacks: [WindowDetectedCallback]
    let placement: DetectedWindowPlacement
    /// Matcher results of the leading callbacks. They must be reused when the callbacks run, because by then
    /// the window is already in its predicted place, but matchers (`if.workspace`) must see the place
    /// the window would occupy by that time without the prediction.
    let matches: [Bool]
}

/// Only callbacks that are cheap and synchronous to evaluate are predicted:
/// - matchers: the legacy `if.*` matchers, the omitted `if`, and `if` commands made of `test`, `test-not`, `true`
///   and `false` joined with `&&` or `||`. `test` must compare one of the variables known before the window is bound
///   to the tree: `%{app-bundle-id}`, `%{app-name}`, `%{window-title}` and `%{workspace}`
/// - runs: the leading `layout floating|tiling` and `move-node-to-workspace <name>` commands without flags
///
/// The prediction stops at the first matcher that can't be predicted, or at the first matched run that has other commands.
/// `title` is nil when it wasn't read; then callbacks that match the title aren't predicted.
@MainActor
func predictOnWindowDetected(
    windowId: OpaqueWindowId,
    initialPlacement: DetectedWindowPlacement,
    app: any AbstractApp,
    title: String?,
) -> OnWindowDetectedPrediction? {
    // The layout is applied around the callbacks, and the window that consumes it is known only when the callbacks run
    if global_layoutForNextDetectedWindow != nil { return nil }
    // The window is going to be restored to its place in the closed windows cache. The callbacks won't run
    if isInClosedWindowsCache(windowId) { return nil }

    let callbacks = config.onWindowDetected
    var placement = initialPlacement
    var matches: [Bool] = []
    for callback in callbacks {
        guard let isMatch = callback.matcher.predictMatch(app, workspace: placement.workspace, title: title) else { break }
        matches.append(isMatch)
        if !isMatch { continue }
        let (commands, isPlacementOnly) = callback.run.leadingPlacementCommands()
        for command in commands {
            placement = command.apply(to: placement)
        }
        if !isPlacementOnly || !callback.checkFurtherCallbacks { break }
    }
    return OnWindowDetectedPrediction(callbacks: callbacks, placement: placement, matches: matches)
}

extension WindowDetectedCallbackMatcher {
    var needsWindowTitle: Bool {
        switch self {
            case .legacy(let matcher): matcher.windowTitleRegexSubstring != nil
            case .command(let shell): shell.flatten().contains { $0.predictableCondition?.testLhs == .window(.windowTitle) }
        }
    }

    /// nil if the result can't be predicted
    @MainActor
    fileprivate func predictMatch(_ app: any AbstractApp, workspace: Workspace, title: String?) -> Bool? {
        switch self {
            case .legacy(let matcher):
                if matcher.windowTitleRegexSubstring != nil && title == nil { return nil }
                return matcher.matches(app, workspace: workspace.name, title: title)
            case .command(let shell):
                // Commands can't just be run: they need the window to be bound to the tree, and running them refreshes the model.
                // Instead, the conditions are evaluated against what the window is going to see
                return shell.predictCondition(PredictedWindowFacts(app: app, workspace: workspace, title: title))
        }
    }
}

/// What `test` sees through the interpolation variables, known before the window is bound to the tree
private struct PredictedWindowFacts {
    let app: any AbstractApp
    /// The workspace the window is going to be in by the time the matcher runs
    let workspace: Workspace
    let title: String?

    /// Mirrors FormatVar.expandFormatVar for a window. nil for the variables that can't be predicted
    @MainActor
    func expand(_ formatVar: FormatVar) -> Primitive? {
        switch formatVar {
            // Evaluated by the same code as the real command, because the window's app variables are the app's variables
            case .app(.appBundleId), .app(.appName): formatVar.expandFormatVar(obj: .app(app)).getIgnoringErrorsOrNil()
            case .window(.windowTitle): title.map(Primitive.string)
            case .workspace(.workspaceName): .string(workspace.name)
            // The rest either depend on the place in the tree or aren't worth predicting
            case .app, .window, .workspace, .monitor: nil
        }
    }
}

private enum PredictableCondition {
    case constant(Bool)
    case test(TestCmdArgs, isNegated: Bool)

    var testLhs: FormatVar? {
        switch self {
            case .constant: nil
            case .test(let args, _): args.lhs.val
        }
    }

    /// Mirrors TestCommand and TestNotCommand. nil when the real command would fail. Then the failure is left to the real command,
    /// which reports it
    @MainActor
    func evaluate(_ facts: PredictedWindowFacts) -> Bool? {
        switch self {
            case .constant(let result): return result
            case .test(let args, let isNegated):
                guard let lhs = facts.expand(args.lhs.val) else { return nil }
                return args.evaluate(lhs: lhs).getIgnoringErrorsOrNil().map { $0 != isNegated }
        }
    }
}

extension Command {
    fileprivate var predictableCondition: PredictableCondition? {
        switch self {
            case is TrueCommand: .constant(true)
            case is FalseCommand: .constant(false)
            case let command as TestCommand: .test(command.args, isNegated: false)
            case let command as TestNotCommand: .test(command.args.testArgs, isNegated: true)
            default: nil
        }
    }
}

extension Shell where T == any Command {
    /// Mirrors Shell.run for the exit code of the conditions. nil if the result can't be predicted
    @MainActor
    fileprivate func predictCondition(_ facts: PredictedWindowFacts) -> Bool? {
        switch self {
            case .empty: // Omitted `if`
                return true
            case .cmd(let command):
                return command.predictableCondition?.evaluate(facts)
            // Short-circuiting the same way as Shell.run, so the operands after the deciding one don't need to be predictable
            case .and(let shells):
                for shell in shells {
                    guard let result = shell.predictCondition(facts) else { return nil }
                    if !result { return false }
                }
                return true
            case .or(let shells):
                for shell in shells {
                    guard let result = shell.predictCondition(facts) else { return nil }
                    if result { return true }
                }
                return false
            case .seq, .pipe:
                return nil
        }
    }
}

private enum PlacementCommand {
    case layout(isFloating: Bool)
    case moveNodeToWorkspace(String)

    /// Mirrors LayoutCommand and MoveNodeToWorkspaceCommand
    @MainActor
    func apply(to placement: DetectedWindowPlacement) -> DetectedWindowPlacement {
        var result = placement
        switch self {
            case .layout(isFloating: true):
                result.kind = .floating
            case .layout(isFloating: false):
                if placement.kind == .floating {
                    result.kind = .newTilingWindow
                }
            case .moveNodeToWorkspace(let name):
                let workspace = Workspace.get(byName: name)
                if workspace != placement.workspace {
                    result.workspace = workspace
                    result.kind = placement.kind == .floating ? .floating : .appendedToRootTilingContainer
                }
        }
        return result
    }
}

extension Shell where T == any Command {
    /// The placement commands the shell starts with, and whether the shell consists only of them
    fileprivate func leadingPlacementCommands() -> (commands: [PlacementCommand], isPlacementOnly: Bool) {
        switch self {
            case .empty:
                return ([], true)
            case .cmd(let command):
                return command.asPlacementCommand.map { ([$0], true) } ?? ([], false)
            // `&&` is the same as `;` here, because placement commands succeed for the detected window
            case .seq(let shells), .and(let shells):
                var result: [PlacementCommand] = []
                for shell in shells {
                    let (commands, isPlacementOnly) = shell.leadingPlacementCommands()
                    result += commands
                    if !isPlacementOnly { return (result, false) }
                }
                return (result, true)
            case .or, .pipe:
                return ([], false)
        }
    }
}

extension Command {
    /// Flags are rejected because they either target something else, change the focus,
    /// or change the exit code when the command is a no-op (`--fail-if-noop`)
    fileprivate var asPlacementCommand: PlacementCommand? {
        switch self {
            case let command as LayoutCommand:
                let args = command.args
                if args.forNextDetectedWindow || args.root || args.failIfNoop || args.windowId != nil || args.workspaceName != nil {
                    return nil
                }
                return switch args.toggleBetween.val.singleOrNil() {
                    case .floating: .layout(isFloating: true)
                    case .tiling: .layout(isFloating: false)
                    default: nil
                }
            case let command as MoveNodeToWorkspaceCommand:
                let args = command.args
                if args.failIfNoop || args.focusFollowsWindow || args.windowId != nil {
                    return nil
                }
                return switch args.target.val {
                    case .direct(let name): .moveNodeToWorkspace(name.raw)
                    case .relative: nil
                }
            default:
                return nil
        }
    }
}
