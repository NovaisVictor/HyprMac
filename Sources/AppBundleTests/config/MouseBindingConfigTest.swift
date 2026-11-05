@testable import AppBundle
import AppKit
import Common
import HotKey
import Testing

@MainActor
@Suite(.serializedGlobally)
struct MouseBindingConfigTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParseMouseBindings() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-h = 'focus left'
                alt-leftMouse = 'grab-and-move'
                ctrl-alt-rightMouse = ['grab-and-resize']
            [mode.service.binding]
                middleMouse = 'grab-and-move'
            """,
        )
        assertEquals(result.errors, [])
        let keyboardBinding = HotkeyBinding(.option, .h, .cmd(FocusCommand.new(direction: .left)))
        let main = result.config.modes[mainModeId]
        assertEquals(main?.bindings, [keyboardBinding.descriptionWithKeyCode: keyboardBinding])
        assertEquals(main?.mouseBindings.mapValues(\.grabKind), ["alt-leftMouse": .move, "alt-ctrl-rightMouse": .resize])
        assertEquals(main?.mouseBindings["alt-ctrl-rightMouse"]?.modifiers, [.option, .control])
        assertEquals(main?.mouseBindings["alt-ctrl-rightMouse"]?.button, .right)
        assertEquals(main?.mouseBindings["alt-ctrl-rightMouse"]?.descriptionWithKeyNotation, "ctrl-alt-rightMouse")
        assertEquals(result.config.modes["service"]?.mouseBindings["middleMouse"]?.modifiers, [])
        assertEquals(result.config.modes["service"]?.bindings, [:])
    }

    @Test func testMouseBindingValidation() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-leftMouse = 'focus left'
                alt-rightMouse = 'grab-and-move; grab-and-resize'
                leftMouse = 'grab-and-move'
                foo-middleMouse = 'grab-and-move'
                alt-g = 'grab-and-move'
                alt-h = ['focus left', 'grab-and-resize']
                alt-leftmouse = 'grab-and-move'
            """,
        )
        assertEquals(result.strErrors, [
            "[ERROR] mode.main.binding.alt-g: grab-and-move can only be triggered by a mouse binding (e.g. alt-leftMouse)",
            "[ERROR] mode.main.binding.alt-h: grab-and-resize can only be triggered by a mouse binding (e.g. alt-leftMouse)",
            "[ERROR] mode.main.binding.alt-leftMouse: Mouse bindings support only a single 'grab-and-move' or 'grab-and-resize' command",
            "[ERROR] mode.main.binding.alt-leftmouse: Can't parse the key in 'alt-leftmouse' binding. Did you mean 'leftMouse'?",
            "[ERROR] mode.main.binding.alt-rightMouse: Mouse bindings support only a single 'grab-and-move' or 'grab-and-resize' command",
            "[ERROR] mode.main.binding.foo-middleMouse: Can't parse modifiers in 'foo-middleMouse' binding",
            "[ERROR] mode.main.binding.leftMouse: 'leftMouse' binding without modifiers would intercept every click in 'main' mode. Add a modifier, e.g. 'alt-leftMouse'",
        ])
        assertEquals(result.config.modes[mainModeId]?.mouseBindings, [:])
    }

    @Test func testSideSpecificModifiers() {
        let result = parseConfig(
            """
            [mode.main.binding]
                lalt-leftMouse = 'grab-and-move'
                ralt-leftMouse = 'grab-and-resize'
                alt-leftMouse = 'grab-and-move'
                shift-rcmd-lctrl-rightMouse = 'grab-and-move'
                lalt-ralt-middleMouse = 'grab-and-move'
            """,
        )
        assertEquals(result.strErrors, [])
        let bindings = result.config.modes[mainModeId]?.mouseBindings ?? [:]
        assertEquals(bindings.keys.sorted(), ["alt-leftMouse", "lalt-leftMouse", "lalt-ralt-middleMouse", "lctrl-rcmd-shift-rightMouse", "ralt-leftMouse"])
        assertEquals(bindings["lalt-leftMouse"]?.modifiers, .option)
        assertEquals(bindings["lalt-leftMouse"]?.sideSpecificModifiers, CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK)))
        assertEquals(bindings["alt-leftMouse"]?.sideSpecificModifiers, [])
        assertEquals(bindings["lctrl-rcmd-shift-rightMouse"]?.modifiers, [.control, .command, .shift])
        assertEquals(
            bindings["lctrl-rcmd-shift-rightMouse"]?.trigger,
            MouseGrabTrigger(
                modifiers: [.maskControl, .maskCommand, .maskShift],
                sideSpecificModifiers: CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK | NX_DEVICERCMDKEYMASK)),
                button: .right,
                kind: .move,
            ),
        )
        assertEquals(bindings["lctrl-rcmd-shift-rightMouse"]?.descriptionWithKeyNotation, "shift-rcmd-lctrl-rightMouse")
    }

    @Test func testSideSpecificModifiersValidation() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-lalt-leftMouse = 'grab-and-move'
                rshift-ctrl-shift-rightMouse = 'grab-and-move'
                lfoo-middleMouse = 'grab-and-move'
                lalt-h = 'focus left'
            [mode.service.binding]
                lalt-leftMouse = 'grab-and-move'
                alt-lalt-leftMouse = 'grab-and-move'
            """,
        )
        assertEquals(result.strErrors.sorted(), [
            "[ERROR] mode.main.binding.alt-lalt-leftMouse: 'alt-lalt-leftMouse' binding combines 'alt' with its side-specific variant. 'alt' already matches either side",
            "[ERROR] mode.main.binding.lalt-h: Can't parse modifiers in 'lalt-h' binding",
            "[ERROR] mode.main.binding.lfoo-middleMouse: Can't parse modifiers in 'lfoo-middleMouse' binding",
            "[ERROR] mode.main.binding.rshift-ctrl-shift-rightMouse: 'rshift-ctrl-shift-rightMouse' binding combines 'shift' with its side-specific variant. 'shift' already matches either side",
            "[ERROR] mode.service.binding.alt-lalt-leftMouse: 'alt-lalt-leftMouse' binding combines 'alt' with its side-specific variant. 'alt' already matches either side",
        ])
    }

    @Test func testSideSpecificRedeclaration() {
        let result = parseConfig(
            """
            [mode.main.binding]
                lalt-shift-leftMouse = 'grab-and-move'
                shift-lalt-leftMouse = 'grab-and-resize'
            """,
        )
        assertEquals(result.strErrors.count, 1)
        assertTrue(result.strErrors.first?.contains("'lalt-shift-leftMouse' Binding redeclaration") == true)
    }

    @Test func testMouseBindingRedeclaration() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-shift-leftMouse = 'grab-and-move'
                shift-alt-leftMouse = 'grab-and-resize'
            """,
        )
        assertEquals(result.strErrors.count, 1)
        assertTrue(result.strErrors.first?.contains("'alt-shift-leftMouse' Binding redeclaration") == true)
    }

    @Test func testMouseButtonsAreReservedInKeyMapping() {
        let result = parseConfig(
            """
            [key-mapping.key-notation-to-key-code]
                leftMouse = 'a'
            """,
        )
        assertEquals(result.strErrors, ["[ERROR] key-mapping.key-notation-to-key-code.leftMouse: 'leftMouse' is reserved for mouse bindings"])
    }

    @Test func testGrabCommandsFailOutsideOfMouseBinding() async {
        let move = await parseCommand("grab-and-move").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(move.exitCode.rawValue, 2)
        assertEquals(move.stderr, ["grab-and-move can only be triggered by a mouse binding (e.g. alt-leftMouse)"])

        let resize = await parseCommand("grab-and-resize").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(resize.exitCode.rawValue, 2)
        assertEquals(resize.stderr, ["grab-and-resize can only be triggered by a mouse binding (e.g. alt-leftMouse)"])
    }

    @Test func testTriggerMouseBindingFails() async {
        config.modes = parseConfig(
            """
            [mode.main.binding]
                alt-leftMouse = 'grab-and-move'
            """,
        ).config.modes
        let result = await parseCommand("trigger-binding --mode main alt-leftMouse").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["grab-and-move can only be triggered by a mouse binding (e.g. alt-leftMouse)"])
    }

    @Test func testConfigDumpContainsMouseBindings() async {
        config.modes = parseConfig(
            """
            [mode.main.binding]
                alt-leftMouse = 'grab-and-move'
            """,
        ).config.modes
        let result = await parseCommand("config --get mode.main.binding.alt-leftMouse").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, ["grab-and-move"])
    }
}
