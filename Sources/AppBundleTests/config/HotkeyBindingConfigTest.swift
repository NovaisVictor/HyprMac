@testable import AppBundle
import AppKit
import Common
import HotKey
import Testing

@MainActor
@Suite(.serializedGlobally)
struct HotkeyBindingConfigTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParseInlineTable() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-h = 'focus left'
                alt-j = ['focus down', 'focus up']
                alt-x = { run = 'focus right', on = 'release' }
                alt-k = { run = ['focus up'], repeat = true }
                alt-l = { run = 'focus left', on = 'press', repeat = false }
            """,
        )
        assertEquals(result.errors, [])
        let bindings = result.config.modes[mainModeId]?.bindings ?? [:]
        assertEquals(bindings.mapValues(\.trigger), ["alt-h": .press, "alt-j": .press, "alt-x": .release, "alt-k": .press, "alt-l": .press])
        assertEquals(bindings.mapValues(\.repeats), ["alt-h": false, "alt-j": false, "alt-x": false, "alt-k": true, "alt-l": false])
        assertEquals(bindings["alt-x"], HotkeyBinding(.option, .x, .cmd(FocusCommand.new(direction: .right)), trigger: .release, descriptionWithKeyNotation: "alt-x"))
        assertEquals(bindings["alt-k"]?.commands.shellOfCommandsDescription, "focus up")
    }

    @Test func testInlineTableErrors() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-a = { run = 'focus left', on = 'release', repeat = true }
                alt-b = { on = 'release' }
                alt-c = { run = 'focus left', on = 'hold' }
                alt-d = { run = 'focus left', repeat = 'yes' }
                alt-e = { run = 'focus left', foo = 1 }
                alt-f = {}
                alt-g = { run = 'grab-and-move' }
                alt-h = { run = 'foo' }
            """,
        )
        assertEquals(result.strErrors.sorted(), [
            "[ERROR] mode.main.binding.alt-a.repeat: 'repeat = true' is incompatible with 'on = 'release''",
            "[ERROR] mode.main.binding.alt-b: 'run' is mandatory",
            "[ERROR] mode.main.binding.alt-c.on: Can't parse 'hold'. Possible values: press, release",
            "[ERROR] mode.main.binding.alt-d.repeat: Expected type is 'Bool'. But actual type is 'String'",
            "[ERROR] mode.main.binding.alt-e.foo: Unknown key",
            "[ERROR] mode.main.binding.alt-f: 'run' is mandatory",
            "[ERROR] mode.main.binding.alt-f: empty table is not allowed here",
            "[ERROR] mode.main.binding.alt-g: grab-and-move can only be triggered by a mouse binding (e.g. alt-leftMouse)",
            "[ERROR] mode.main.binding.alt-h.run: Unrecognized subcommand 'foo'",
        ])
    }

    @Test func testWrongValueTypeMentionsInlineTables() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-h = 1
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] mode.main.binding.alt-h: Expected types are 'string' or 'array' or 'table'. But actual type is 'int'",
        ])
    }

    @Test func testMouseBindingsDontAcceptInlineTables() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-leftMouse = { run = 'grab-and-move' }
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] mode.main.binding.alt-leftMouse: Expected types are 'string' or 'array'. But actual type is 'table'",
        ])
    }

    @Test func testTriggerBindingRunsReleaseBinding() async {
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(Window.get(byId: 2)?.focusWindow(), true)
        let commands = parseCommand("focus left").cmdOrDie
        let binding = HotkeyBinding(.option, .x, commands, trigger: .release, descriptionWithKeyNotation: "alt-x")
        config.modes = [mainModeId: Mode(bindings: [binding.descriptionWithKeyCode: binding])]

        let result = await parseCommand("trigger-binding alt-x --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
    }

    @Test func testConfigCommandPrintsCommandsOfInlineTables() async {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-x = { run = 'focus right', on = 'release' }
            """,
        )
        assertEquals(result.errors, [])
        config = result.config
        let output = await parseCommand("config --get mode.main.binding.alt-x").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(output.exitCode.rawValue, 0)
        assertEquals(output.stdout, ["focus right"])
    }
}
