@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct OnWindowTitleChangedConfigTest {
    @Test func testParseLegacyMatcher() {
        let result = parseConfig(
            """
            [[on-window-title-changed]]
            if.app-id = 'com.google.Chrome'
            if.window-title-regex-substring = 'Meet'
            run = 'move-node-to-workspace M'
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.onWindowTitleChanged, [
            WindowDetectedCallback(
                matcher: .legacy(LegacyWindowDetectedCallbackMatcher(
                    appId: "com.google.Chrome",
                    windowTitleRegexSubstring: .new("Meet").getOrDie(),
                )),
                rawRun: .cmd(MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "M"))),
            ),
        ])
        assertEquals(result.config.onWindowDetected, [])
    }

    @Test func testParseCommandMatcherAndCheckFurtherCallbacks() {
        let result = parseConfig(
            """
            [[on-window-title-changed]]
            if = 'test %{window-title} ~= "Picture-in-picture Window"'
            check-further-callbacks = true
            run = 'layout floating'
            """,
        )
        assertEquals(result.errors, [])
        let callback = result.config.onWindowTitleChanged.singleOrNil()
        assertEquals(callback?.checkFurtherCallbacks, true)
        assertEquals(callback?.matcher.needsWindowTitle, true)
    }

    @Test func testDuringAeroSpaceStartupIsRejected() {
        let result = parseConfig(
            """
            [[on-window-title-changed]]
            if.during-hyprmac-startup = false
            run = 'layout floating'
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] on-window-title-changed[0].if.during-hyprmac-startup: 'during-hyprmac-startup' isn't supported in 'on-window-title-changed'",
        ])
        assertEquals(result.config.onWindowTitleChanged, [])
    }

    @Test func testDuringAeroSpaceStartupIsStillAllowedInOnWindowDetected() {
        let result = parseConfig(
            """
            [[on-window-detected]]
            if.during-hyprmac-startup = false
            run = 'layout floating'
            """,
        )
        assertEquals(result.errors, [])
    }

    @Test func testTheSameValidationAsOnWindowDetected() {
        let result = parseConfig(
            """
            on-window-title-changed = [
                {},
                { run = 'layout floating' },
                { if = 'true' },
            ]
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] on-window-title-changed[0]: empty table is not allowed here",
            "[ERROR] on-window-title-changed[0]: Omitting 'if' is error prone. You can use `if = 'true'` to preserve the previous behavior.\nBut heads up! You may have missed 'check-further-callbacks = true'",
            "[ERROR] on-window-title-changed[0]: 'run' is mandatory key",
            "[ERROR] on-window-title-changed[1]: Omitting 'if' is error prone. You can use `if = 'true'` to preserve the previous behavior.\nBut heads up! You may have missed 'check-further-callbacks = true'",
            "[ERROR] on-window-title-changed[2]: 'run' is mandatory key",
        ])
    }

    @Test func testWrongType() {
        let result = parseConfig("on-window-title-changed = 'layout floating'")
        assertEquals(result.strErrors, ["[ERROR] on-window-title-changed: Expected type is 'Array'. But actual type is 'String'"])
    }

    @Test func testDefaultConfigHasNoTitleCallbacks() {
        assertEquals(defaultConfig.onWindowTitleChanged, [])
    }
}
