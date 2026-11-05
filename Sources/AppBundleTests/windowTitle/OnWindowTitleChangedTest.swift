@testable import AppBundle
import AppKit
import Common
import Testing

/// Not `.succ`: Int32ExitCode.succ is 2
private let succ = Int32ExitCode(rawValue: EXIT_CODE_ZERO)

@MainActor
@Suite(.serializedGlobally)
struct OnWindowTitleChangedTest {
    init() { setUpWorkspacesForTests() }

    private func callback(_ condition: String, _ run: String, checkFurtherCallbacks: Bool = false) -> WindowDetectedCallback {
        WindowDetectedCallback(
            matcher: .command(parseCommand(condition).cmdOrDie),
            checkFurtherCallbacks: checkFurtherCallbacks,
            rawRun: parseCommand(run).cmdOrDie,
        )
    }

    private func useCallbacks(_ callbacks: [WindowDetectedCallback]) {
        config.onWindowTitleChanged = callbacks
        syncWindowTitleObservation(resetState: true)
    }

    /// Counts the runs, the way the debounce loop wraps them in a session
    private final class Runs {
        var count = 0
    }

    private func titleChanged(_ window: Window, _ runs: Runs? = nil, force: Bool = false) async throws -> WindowTitleChangeResult {
        try await handleWindowTitleChange(window, force: force, .defaultEnv, CmdIoImpl.emptyStdinIgnoringOut) { body in
            runs?.count += 1
            return await body()
        }
    }

    private var meetCallback: WindowDetectedCallback {
        callback("test %{window-title} ~= Meet", "move-node-to-workspace M")
    }

    @Test func testObservationIsOptIn() {
        assertEquals(isWindowTitleObservationNeeded, false)
        assertEquals(isWindowTitleObservationEnabled(), false)

        useCallbacks([meetCallback])
        assertEquals(isWindowTitleObservationNeeded, true)
        assertEquals(isWindowTitleObservationEnabled(), true)

        useCallbacks([])
        assertEquals(isWindowTitleObservationEnabled(), false)
    }

    @Test func testTitleSubscriptionIsSeparateFromTheRequiredOnes() {
        // bulkSubscribe is all-or-nothing, so the optional title notification must never be in the required list
        let required = unsafe axWindowHandlers.flatMap(\.1)
        #expect(!required.contains(kAXTitleChangedNotification))
        #expect(required.contains(kAXMovedNotification))
        assertEquals(unsafe windowTitleChangedHandlers.flatMap(\.1), [kAXTitleChangedNotification])
    }

    @Test func testUnchangedTitleIsNoWork() async throws {
        useCallbacks([meetCallback])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Meet - abc"
        try await seedWindowTitleState(window)

        let runs = Runs()
        assertEquals(try await titleChanged(window, runs), .titleUnchanged)
        assertEquals(runs.count, 0)
        assertEquals(window.nodeWorkspace?.name, "a")
    }

    @Test func testEdgeTriggering() async throws {
        useCallbacks([meetCallback])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Inbox"
        try await seedWindowTitleState(window)
        let runs = Runs()

        window.titleForTest = "Meet - abc"
        assertEquals(try await titleChanged(window, runs), .callbacksRan(succ))
        assertEquals(runs.count, 1)
        assertEquals(window.nodeWorkspace?.name, "M")

        // Still matches: no run, even if the user moved the window back
        window.bind(to: Workspace.get(byName: "a").rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        window.titleForTest = "Meet - def"
        assertEquals(try await titleChanged(window, runs), .noCallbackTriggered)
        assertEquals(runs.count, 1)
        assertEquals(window.nodeWorkspace?.name, "a")

        // Stops matching, then matches again: re-armed
        window.titleForTest = "Inbox"
        assertEquals(try await titleChanged(window, runs), .noCallbackTriggered)
        window.titleForTest = "Meet - ghi"
        assertEquals(try await titleChanged(window, runs), .callbacksRan(succ))
        assertEquals(runs.count, 2)
        assertEquals(window.nodeWorkspace?.name, "M")
    }

    @Test func testWindowThatAlreadyMatchedOnDetectionDoesNotTrigger() async throws {
        useCallbacks([meetCallback])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Meet - abc"
        try await seedWindowTitleState(window)

        window.titleForTest = "Meet - def"
        assertEquals(try await titleChanged(window), .noCallbackTriggered)
        assertEquals(window.nodeWorkspace?.name, "a")
    }

    @Test func testTitleThatAppearsAfterDetection() async throws {
        // Picture-in-Picture windows are detected with an empty title, on-window-detected can't match them
        useCallbacks([callback("test %{window-title} ~= 'Picture-in-picture Window'", "layout floating")])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = ""
        try await seedWindowTitleState(window)
        assertEquals(window.isFloating, false)

        window.titleForTest = "Picture-in-picture Window"
        assertEquals(try await titleChanged(window), .callbacksRan(succ))
        assertEquals(window.isFloating, true)
    }

    @Test func testFirstMatchAmongTriggeredCallbacks() async throws {
        useCallbacks([
            callback("true", "move-node-to-workspace X"), // Matched before, so it's transparent
            callback("test %{window-title} ~= Meet", "move-node-to-workspace M"),
            callback("test %{window-title} ~= Meet", "move-node-to-workspace N"),
        ])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Inbox"
        try await seedWindowTitleState(window)

        window.titleForTest = "Meet"
        assertEquals(try await titleChanged(window), .callbacksRan(succ))
        assertEquals(window.nodeWorkspace?.name, "M")
    }

    @Test func testCheckFurtherCallbacks() async throws {
        useCallbacks([
            callback("test %{window-title} ~= Meet", "layout floating", checkFurtherCallbacks: true),
            callback("test %{window-title} ~= Meet", "move-node-to-workspace M"),
            callback("test %{window-title} ~= Meet", "move-node-to-workspace N"),
        ])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Inbox"
        try await seedWindowTitleState(window)

        window.titleForTest = "Meet"
        assertEquals(try await titleChanged(window), .callbacksRan(succ))
        assertEquals(window.isFloating, true)
        assertEquals(window.nodeWorkspace?.name, "M")
    }

    @Test func testLegacyMatcher() async throws {
        useCallbacks([
            WindowDetectedCallback(
                matcher: .legacy(LegacyWindowDetectedCallbackMatcher(windowTitleRegexSubstring: .new("meet").getOrDie())),
                rawRun: parseCommand("move-node-to-workspace M").cmdOrDie,
            ),
        ])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Inbox"
        try await seedWindowTitleState(window)

        window.titleForTest = "Google Meet"
        assertEquals(try await titleChanged(window), .callbacksRan(succ))
        assertEquals(window.nodeWorkspace?.name, "M")
    }

    @Test func testReentryGuard() async throws {
        useCallbacks([meetCallback])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Inbox"
        try await seedWindowTitleState(window)

        window.titleForTest = "Meet"
        var nested: WindowTitleChangeResult? = nil
        let result = try await handleWindowTitleChange(window, force: false, .defaultEnv, CmdIoImpl.emptyStdinIgnoringOut) { body in
            window.titleForTest = "Meet - changed by the callback"
            nested = try await titleChanged(window)
            return await body()
        }
        assertEquals(result, .callbacksRan(succ))
        assertEquals(nested, .busy)

        // The guard is released afterward
        window.titleForTest = "Inbox"
        assertEquals(try await titleChanged(window), .noCallbackTriggered)
    }

    @Test func testRunCallbackCommandIsReentrant() async throws {
        useCallbacks([callback("test %{window-title} ~= Meet", "run-callback on-window-title-changed")])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Inbox"
        try await seedWindowTitleState(window)

        window.titleForTest = "Meet"
        assertEquals(try await titleChanged(window), .callbacksRan(.fail))
    }

    @Test func testPopupsAreIgnored() async throws {
        useCallbacks([meetCallback])
        let window = TestWindow.new(id: 1, parent: macosPopupWindowsContainer)
        defer { window.unbindFromParent() }
        window.titleForTest = "Meet"
        assertEquals(try await titleChanged(window), .ignored)
    }

    @Test func testNoCallbacksOnlyTracksTheTitle() async throws {
        useCallbacks([])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Meet"
        assertEquals(try await titleChanged(window), .noCallbackTriggered)
        assertEquals(windowTitleStates[1], WindowTitleState(lastKnownTitle: "Meet", matches: []))
        assertEquals(try await titleChanged(window), .titleUnchanged)
    }

    @Test func testConfigReloadForgetsTheState() async throws {
        useCallbacks([meetCallback])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Inbox"
        try await seedWindowTitleState(window)
        #expect(windowTitleStates[1] != nil)

        syncWindowTitleObservation(resetState: true)
        assertEquals(windowTitleStates[1], nil)
    }

    @Test func testForgetOnGarbageCollection() async throws {
        useCallbacks([meetCallback])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        try await seedWindowTitleState(window)
        forgetWindowTitleState(1)
        assertEquals(windowTitleStates[1], nil)
    }

    @Test func testRunCallbackForcesTheRun() async throws {
        useCallbacks([meetCallback])
        let workspaceA = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: workspaceA.rootTilingContainer)
        window.titleForTest = "Meet"
        try await seedWindowTitleState(window) // Already matches, an ordinary title change wouldn't run it

        let result = await parseCommand("run-callback --window-id 1 on-window-title-changed").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, succ)
        assertEquals(window.nodeWorkspace?.name, "M")
    }

    @Test func testRunCallbackWithoutMatches() async {
        useCallbacks([meetCallback])
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        window.titleForTest = "Inbox"

        let result = await parseCommand("run-callback --window-id 1 on-window-title-changed").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, succ)
        assertEquals(window.nodeWorkspace?.name, "a")
    }
}
