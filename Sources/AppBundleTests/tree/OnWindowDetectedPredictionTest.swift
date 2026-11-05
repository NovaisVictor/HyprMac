@testable import AppBundle
import AppKit
import Common
import Testing

private let testAppId = "com.victornovais.HyprMac.test-app"
private let detectedWindowId: OpaqueWindowId = 100

@MainActor
@Suite(.serializedGlobally)
struct OnWindowDetectedPredictionTest {
    init() { setUpWorkspacesForTests() }

    @Test func testMoveToAnotherWorkspaceDoesntTouchFocusedWorkspace() async {
        config.newWindowPlacement = .dwindle
        setCallbacks(
            """
            on-window-detected = [
                { if.app-id = '\(testAppId)', run = 'move-node-to-workspace b' },
            ]
            """,
        )
        let focused = setUpFocusedWorkspace()

        let (window, prediction) = bindDetectedWindow(predict: true)
        assertEquals(prediction?.matches, [true])
        assertEquals(window.nodeWorkspace?.name, "b")
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))

        await runOnWindowDetected(ifConventional: window, prediction)
        assertEquals(window.nodeWorkspace?.name, "b")
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    @Test func testWithoutPredictionDwindleSplitLeavesStrayContainer() async {
        config.newWindowPlacement = .dwindle
        setCallbacks(
            """
            on-window-detected = [
                { if.app-id = '\(testAppId)', run = 'move-node-to-workspace b' },
            ]
            """,
        )
        let focused = setUpFocusedWorkspace()

        let (window, _) = bindDetectedWindow(predict: false)
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(detectedWindowId)])]))

        await runOnWindowDetected(ifConventional: window)
        assertEquals(window.nodeWorkspace?.name, "b")
        // That's the problem the prediction solves when the flatten normalization is disabled
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2)])]))
    }

    @Test func testFloatingIsPreBound() async {
        config.newWindowPlacement = .dwindle
        setCallbacks(
            """
            on-window-detected = [
                { if.app-id = '\(testAppId)', run = 'layout floating' },
            ]
            """,
        )
        let focused = setUpFocusedWorkspace()

        let (window, prediction) = bindDetectedWindow(predict: true)
        assertEquals(prediction?.placement, DetectedWindowPlacement(workspace: focused, kind: .floating))
        assertTrue(window.isFloating)
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))

        await runOnWindowDetected(ifConventional: window, prediction)
        assertTrue(window.isFloating)
        assertEquals(window.nodeWorkspace, focused)
    }

    @Test func testWindowTitleMatcher() {
        setCallbacks(
            """
            on-window-detected = [
                { if.window-title-regex-substring = 'picture-in-picture', run = 'layout floating' },
            ]
            """,
        )
        let focused = setUpFocusedWorkspace()
        let initial = DetectedWindowPlacement(workspace: focused, kind: .newTilingWindow)

        let matching = predictOnWindowDetected(windowId: detectedWindowId, initialPlacement: initial, app: TestApp.shared, title: "Picture-in-Picture Window")
        assertEquals(matching?.placement.kind, .floating)
        assertEquals(matching?.matches, [true])

        let notMatching = predictOnWindowDetected(windowId: detectedWindowId, initialPlacement: initial, app: TestApp.shared, title: "Main")
        assertEquals(notMatching?.placement, initial)
        assertEquals(notMatching?.matches, [false])

        let unknownTitle = predictOnWindowDetected(windowId: detectedWindowId, initialPlacement: initial, app: TestApp.shared, title: nil)
        assertEquals(unknownTitle?.placement, initial)
        assertEquals(unknownTitle?.matches, [])
    }

    @Test func testUserConfig() async {
        config.newWindowPlacement = .dwindle
        setCallbacks(userConfig(appRun: "['layout tiling', 'move-node-to-workspace W']"))
        let focused = setUpFocusedWorkspace()

        let (window, prediction) = bindDetectedWindow(predict: true)
        assertEquals(prediction?.matches, [false, true, false, true])
        assertEquals(prediction?.placement, DetectedWindowPlacement(workspace: Workspace.get(byName: "W"), kind: .appendedToRootTilingContainer))
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))

        await runOnWindowDetected(ifConventional: window, prediction)
        assertEquals(window.nodeWorkspace?.name, "W")
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    @Test func testUnpredictableCommandMatcherStopsPrediction() {
        setCallbacks(
            """
            on-window-detected = [
                { if.app-id = 'com.apple.finder', run = 'layout floating' },
                { if = 'test %{window-id} = \(detectedWindowId)', run = 'move-node-to-workspace b' },
            ]
            """,
        )
        let (_, prediction) = bindDetectedWindow(predict: true)
        assertEquals(prediction?.matches, [false])
        assertEquals(prediction?.placement.kind, .newTilingWindow)
    }

    @Test func testTestCommandMatcherIsPredicted() async {
        config.newWindowPlacement = .dwindle
        setCallbacks(
            """
            on-window-detected = [
                { if = 'test %{app-bundle-id} = com.apple.finder', run = 'layout floating' },
                { if = 'test %{app-bundle-id} = \(testAppId)', run = 'move-node-to-workspace b' },
            ]
            """,
        )
        let focused = setUpFocusedWorkspace()

        let (window, prediction) = bindDetectedWindow(predict: true)
        assertEquals(prediction?.matches, [false, true])
        assertEquals(window.nodeWorkspace?.name, "b")
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))

        await runOnWindowDetected(ifConventional: window, prediction)
        assertEquals(window.nodeWorkspace?.name, "b")
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    @Test func testWindowTitleIsNeededOnlyForWindowTitleTests() {
        func needsTitle(_ raw: String) -> Bool {
            WindowDetectedCallbackMatcher.command(parseCommand(raw, allowExecAndForget: false, allowEval: false).cmdOrDie).needsWindowTitle
        }
        assertTrue(needsTitle(#"test %{window-title} ~= "Picture-in-picture Window""#))
        assertTrue(needsTitle("test %{app-bundle-id} = foo || test-not %{window-title} = bar"))
        assertFalse(needsTitle("test %{app-bundle-id} = foo"))
        assertFalse(needsTitle("true"))
    }

    /// The prediction must give the same result as running the matcher once the window is bound to the tree
    @Test func testTestCommandPredictionIsEquivalentToRealCommand() async {
        let focused = setUpFocusedWorkspace()
        let window = TestWindow.new(id: detectedWindowId, parent: focused.rootTilingContainer)
        let title = try! await window.getTitle(.nonCancellable)
        let cases: [(matcher: String, isPredictable: Bool)] = [
            ("test %{app-bundle-id} = \(testAppId)", true),
            ("test %{app-bundle-id} = COM.VICTORNOVAIS.HyprMac.test-app", true), // `=` is case-sensitive
            ("test %{app-bundle-id} = com", true),
            ("test %{app-bundle-id} = '\(testAppId)'", true),
            ("test %{app-bundle-id} ~= HYPR", true), // `~=` is a case-insensitive contains
            ("test %{app-bundle-id} ~= zzz", true),
            (#"test %{app-bundle-id} ~= '^com\.victornovais\.'"#, true),
            (#"test %{app-bundle-id} ~= "^(com\.todesktop\.230313mzl4w4u92|com\.victornovais\.HyprMac\.test-app)$""#, true),
            (#"test %{app-bundle-id} ~= "^(com\.todesktop\.230313mzl4w4u92|com\.github\.wez\.wezterm)$""#, true),
            (#"test %{app-bundle-id} ~= "^HyprMac""#, true),
            ("test %{app-name} = \(testAppId)", true),
            ("test %{app-name} ~= TEST-APP", true),
            (#"test %{window-title} ~= "Picture-in-picture Window""#, true),
            ("test %{window-title} ~= testwindow", true),
            ("test %{window-title} = '\(title)'", true),
            ("test %{window-title} = testwindow", true),
            ("test %{workspace} = \(focused.name)", true),
            ("test %{workspace} = b", true),
            ("test %{workspace} ~= '^\(focused.name)$'", true),
            ("test-not %{app-bundle-id} = \(testAppId)", true),
            ("test-not %{window-title} ~= pip", true),
            ("true", true),
            ("false", true),
            ("test %{app-bundle-id} = foo || test %{app-name} ~= aero", true),
            ("test %{app-bundle-id} = foo || test %{app-name} ~= foo", true),
            ("test %{app-bundle-id} ~= aero && test-not %{window-title} ~= pip", true),
            ("test %{app-bundle-id} ~= aero && test %{window-title} ~= pip", true),
            ("test %{app-bundle-id} = foo || test %{app-bundle-id} ~= aero && test %{workspace} = b", true),
            // The operands after the deciding one aren't evaluated
            ("false && test %{window-id} = \(detectedWindowId)", true),
            ("true || test %{window-id} = 1", true),
            ("test %{window-id} = \(detectedWindowId)", false),
            ("test %{window-layout} = h_tiles", false),
            ("test %{app-pid} = 0", false),
            ("test %{workspace-is-focused} = true", false),
            ("test %{monitor-name} ~= foo", false),
            ("test %{app-bundle-id} ~= '['", false), // The real command fails
            ("test-not %{app-bundle-id} ~= '['", false),
            ("test %{app-bundle-id} = foo || test %{window-id} = 1", false),
            ("true && test %{window-id} = \(detectedWindowId)", false),
            ("true; true", false),
        ]
        for (raw, isPredictable) in cases {
            let callback = WindowDetectedCallback(
                matcher: .command(parseCommand(raw, allowExecAndForget: false, allowEval: false).cmdOrDie),
                rawRun: .empty,
            )
            config.onWindowDetected = [callback]
            let initial = DetectedWindowPlacement(workspace: focused, kind: .newTilingWindow)
            let predicted = predictOnWindowDetected(windowId: detectedWindowId, initialPlacement: initial, app: TestApp.shared, title: title)?
                .matches.singleOrNil()
            let actual = await callback.matches(window)
            assertEquals(predicted != nil, isPredictable, additionalMsg: raw)
            if let predicted {
                assertEquals(predicted, actual, additionalMsg: raw)
            }
        }
    }

    @Test func testUnknownTitleIsNotPredicted() {
        setCallbacks(
            """
            on-window-detected = [
                { if = 'test %{window-title} ~= "Picture-in-picture Window"', run = 'layout floating' },
            ]
            """,
        )
        let initial = DetectedWindowPlacement(workspace: globalFocus.workspace, kind: .newTilingWindow)
        let prediction = predictOnWindowDetected(windowId: detectedWindowId, initialPlacement: initial, app: TestApp.shared, title: nil)
        assertEquals(prediction?.matches, [])
        assertEquals(prediction?.placement, initial)
    }

    @Test func testUserCommandConfig() async {
        config.newWindowPlacement = .dwindle
        setCallbacks(userCommandConfig(appRun: "['layout tiling', 'move-node-to-workspace W']"))
        let focused = setUpFocusedWorkspace()

        let (window, prediction) = bindDetectedWindow(predict: true)
        assertEquals(prediction?.matches, [false, false, true])
        assertEquals(prediction?.placement, DetectedWindowPlacement(workspace: Workspace.get(byName: "W"), kind: .appendedToRootTilingContainer))
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))

        await runOnWindowDetected(ifConventional: window, prediction)
        assertEquals(window.nodeWorkspace?.name, "W")
        assertEquals(focused.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    @Test func testUserCommandConfigPictureInPicture() {
        setCallbacks(userCommandConfig(appRun: "'move-node-to-workspace W'"))
        let focused = setUpFocusedWorkspace()
        let initial = DetectedWindowPlacement(workspace: focused, kind: .newTilingWindow)
        let prediction = predictOnWindowDetected(windowId: detectedWindowId, initialPlacement: initial, app: TestApp.shared, title: "Picture-in-Picture Window")
        assertEquals(prediction?.matches, [false, true])
        assertEquals(prediction?.placement, DetectedWindowPlacement(workspace: focused, kind: .floating))
    }

    /// Mirrors the WezTerm rule of a real config: the script places the window by itself
    @Test func testExecAndForgetRunIsNotPreBoundButRuns() async {
        setCallbacks(userCommandConfig(appRun: "['exec-and-forget true', 'layout floating']"))
        let focused = setUpFocusedWorkspace()

        let (window, prediction) = bindDetectedWindow(predict: true)
        assertEquals(prediction?.matches, [false, false, true])
        assertEquals(prediction?.placement, DetectedWindowPlacement(workspace: focused, kind: .newTilingWindow))
        assertFalse(window.isFloating)

        await runOnWindowDetected(ifConventional: window, prediction)
        assertTrue(window.isFloating)
        assertEquals(window.nodeWorkspace, focused)
    }

    @Test func testPredictionStopsAtNonPlacementCommand() {
        setCallbacks(
            """
            on-window-detected = [
                {
                    if.app-id = '\(testAppId)',
                    check-further-callbacks = true,
                    run = ['move-node-to-workspace b', 'flatten-workspace-tree', 'layout floating'],
                },
                { if.app-id = '\(testAppId)', run = 'layout floating' },
            ]
            """,
        )
        let (_, prediction) = bindDetectedWindow(predict: true)
        assertEquals(prediction?.matches, [true])
        assertEquals(prediction?.placement, DetectedWindowPlacement(workspace: Workspace.get(byName: "b"), kind: .appendedToRootTilingContainer))
    }

    @Test func testFlagsAreNotPredicted() {
        for run in ["layout floating --fail-if-noop", "move-node-to-workspace --focus-follows-window b", "move-node-to-workspace next", "layout floating tiling"] {
            setUpWorkspacesForTests()
            setCallbacks(
                """
                on-window-detected = [
                    { if.app-id = '\(testAppId)', run = '\(run)' },
                ]
                """,
            )
            let (_, prediction) = bindDetectedWindow(predict: true)
            assertEquals(prediction?.matches, [true])
            assertEquals(prediction?.placement.kind, .newTilingWindow)
            assertEquals(prediction?.placement.workspace, globalFocus.workspace)
        }
    }

    @Test func testMatchersSeeIntermediateWorkspace() async {
        let focused = setUpFocusedWorkspace()
        setCallbacks(
            """
            on-window-detected = [
                { if.workspace = '\(focused.name)', check-further-callbacks = true, run = 'move-node-to-workspace b' },
                { if.workspace = '\(focused.name)', check-further-callbacks = true, run = 'move-node-to-workspace c' },
                { if.workspace = 'b', run = 'layout floating' },
            ]
            """,
        )
        let (window, prediction) = bindDetectedWindow(predict: true)
        assertEquals(prediction?.matches, [true, false, true])
        assertEquals(prediction?.placement, DetectedWindowPlacement(workspace: Workspace.get(byName: "b"), kind: .floating))

        // The window is already in 'b', but the first matcher must still be considered matched
        await runOnWindowDetected(ifConventional: window, prediction)
        assertEquals(window.nodeWorkspace?.name, "b")
        assertTrue(window.isFloating)
    }

    @Test func testLayoutForNextDetectedWindowDisablesPrediction() {
        setCallbacks(
            """
            on-window-detected = [
                { if.app-id = '\(testAppId)', run = 'move-node-to-workspace b' },
            ]
            """,
        )
        global_layoutForNextDetectedWindow = .floating
        let (_, prediction) = bindDetectedWindow(predict: true)
        assertNil(prediction)
    }

    @Test func testFinalTreeIsTheSameWithAndWithoutPrediction() async {
        let runs = [
            "'layout floating'",
            "'layout tiling'",
            "'move-node-to-workspace b'",
            "'move-node-to-workspace c'",
            "['layout tiling', 'move-node-to-workspace b']",
            "['move-node-to-workspace b', 'layout tiling']",
            "['move-node-to-workspace b', 'layout floating']",
            "['layout floating', 'move-node-to-workspace b', 'layout tiling']",
            "'layout floating && move-node-to-workspace b'",
            "'move-node-to-workspace b; flatten-workspace-tree'",
            "'move-node-to-workspace next'",
        ]
        for dwindle in [false, true] {
            for kind in [DetectedWindowPlacement.Kind.newTilingWindow, .floating] {
                for run in runs {
                    for toml in [userConfig(appRun: run), userCommandConfig(appRun: run)] {
                        let expected = await runScenario(toml, kind: kind, dwindle: dwindle, predict: false)
                        let actual = await runScenario(toml, kind: kind, dwindle: dwindle, predict: true)
                        let msg = "run=\(run) kind=\(kind) dwindle=\(dwindle) config=\(toml)"
                        assertEquals(actual.workspaces, expected.workspaces, additionalMsg: msg)
                        assertEquals(actual.weights, expected.weights, additionalMsg: msg)
                    }
                }
            }
        }
    }
}

@MainActor
private func runScenario(_ toml: String, kind: DetectedWindowPlacement.Kind, dwindle: Bool, predict: Bool) async -> (workspaces: [String: LayoutDescription], weights: [OpaqueWindowId: CGFloat]) {
    setUpWorkspacesForTests()
    // Without it, the stray container that the prediction avoids would make the trees differ
    config.enableNormalizationFlattenContainers = true
    config.newWindowPlacement = dwindle ? .dwindle : .sibling
    setCallbacks(toml)
    setUpFocusedWorkspace()
    TestWindow.new(id: 10, parent: Workspace.get(byName: "b").rootTilingContainer)
    TestWindow.new(id: 11, parent: Workspace.get(byName: "b").rootTilingContainer)

    let (window, prediction) = bindDetectedWindow(predict: predict, kind: kind)
    await runOnWindowDetected(ifConventional: window, prediction)

    var weights: [OpaqueWindowId: CGFloat] = [:]
    for window in Workspace.all.flatMap(\.allLeafWindowsRecursive) {
        if let parent = window.parent as? TilingContainer {
            weights[window.windowId] = window.getWeight(parent.orientation)
        }
    }
    return (
        workspaces: Dictionary(uniqueKeysWithValues: Workspace.all.map { workspace in
            // The floating container is created lazily on the first access, so its absence is not a difference
            let children = workspace.children.filter { !($0 is FloatingWindowsContainer && $0.children.isEmpty) }
            return (workspace.name, LayoutDescription.workspace(children.map(\.layoutDescription)))
        }),
        weights: weights,
    )
}

@MainActor
private func setCallbacks(_ toml: String) {
    let result = parseConfig(toml)
    assertEquals(result.strErrors, [])
    config.onWindowDetected = result.config.onWindowDetected
}

/// The shape of a real user config
private func userConfig(appRun: String) -> String {
    """
    on-window-detected = [
        { if.app-id = 'com.apple.systempreferences', run = 'layout floating' },
        { check-further-callbacks = true, run = 'layout tiling' },
        { if.app-id = 'com.apple.finder', run = 'move-node-to-workspace 3' },
        { if.app-id = '\(testAppId)', run = \(appRun) },
        { if.window-title-regex-substring = 'Picture-in-picture Window', run = 'layout floating' },
    ]
    """
}

/// The shape of a real user config that uses only `if` commands
private func userCommandConfig(appRun: String) -> String {
    #"""
    on-window-detected = [
        { if = 'test %{app-bundle-id} = com.apple.systempreferences', run = 'layout floating' },
        { if = 'test %{window-title} ~= "Picture-in-picture Window"', run = 'layout floating' },
        { if = 'test %{app-bundle-id} ~= "^(com\.todesktop\.230313mzl4w4u92|\#(testAppId.replacing(".", with: #"\."#)))$"', run = \#(appRun) },
        { run = 'layout tiling', check-further-callbacks = true },
    ]
    """#
}

/// The focused workspace: h_tiles[1, 2] where 2 is the focused (and the most recent) window
@discardableResult
@MainActor
private func setUpFocusedWorkspace() -> Workspace {
    let workspace = globalFocus.workspace
    TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
    let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
    window2.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 1000)
    assertTrue(window2.focusWindow())
    return workspace
}

/// Mirrors the registration in MacWindow.getOrRegister
@MainActor
private func bindDetectedWindow(predict: Bool, kind: DetectedWindowPlacement.Kind = .newTilingWindow) -> (TestWindow, OnWindowDetectedPrediction?) {
    let initial = DetectedWindowPlacement(workspace: globalFocus.workspace, kind: kind)
    let title = "TestWindow(\(detectedWindowId))"
    let prediction = predict
        ? predictOnWindowDetected(windowId: detectedWindowId, initialPlacement: initial, app: TestApp.shared, title: title)
        : nil
    let data = (prediction?.placement ?? initial).unbindAndGetBindingData()
    let window = TestWindow.new(id: detectedWindowId, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    return (window, prediction)
}
