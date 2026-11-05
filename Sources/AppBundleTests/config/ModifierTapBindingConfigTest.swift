@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
private final class Recorder {
    var runs: [String] = []
    var preflightCalls = 0
    var requestCalls = 0
    var messages: [Message] = []
}

@MainActor
@Suite(.serializedGlobally)
struct ModifierTapBindingConfigTest {
    init() {
        setUpWorkspacesForTests()
        activeMode = mainModeId
    }

    @Test func testParse() {
        let result = parseConfig(
            """
            [mode.main.binding]
                cmd = { run = 'mode launcher', on = 'release' }
                ralt = { run = ['workspace-back-and-forth'], on = 'release' }
                alt-h = 'focus left'
            [mode.launcher.binding]
                lshift = { run = 'mode main', on = 'release' }
            """,
        )
        assertEquals(result.errors, [])
        let main = result.config.modes[mainModeId]
        assertEquals(main?.modifierTapBindings.keys.sorted(), ["cmd", "ralt"])
        assertEquals(main?.modifierTapBindings["cmd"]?.commands.shellOfCommandsDescription, "mode launcher")
        assertEquals(main?.modifierTapBindings["ralt"]?.descriptionWithKeyNotation, "ralt")
        assertEquals(main?.bindings.keys.sorted(), ["alt-h"])
        assertEquals(main?.mouseBindings, [:])
        assertEquals(result.config.modes["launcher"]?.modifierTapBindings.keys.sorted(), ["lshift"])
    }

    @Test func testValidation() {
        let result = parseConfig(
            """
            [mode.main.binding]
                cmd = 'mode launcher'
                alt = ['mode launcher']
                ctrl = { run = 'mode launcher' }
                shift = { run = 'mode launcher', on = 'press' }
                lcmd = { run = 'mode launcher', on = 'release', repeat = true }
                rcmd = { run = 'mode launcher', on = 'release', repeat = false }
                lalt = { on = 'release' }
                ralt = { run = 'grab-and-move', on = 'release' }
                lctrl = { run = 'foo', on = 'release' }
                rshift = 1
                fn = { run = 'mode launcher', on = 'release' }
            """,
        )
        assertEquals(result.strErrors.sorted(), [
            "[ERROR] mode.main.binding.alt: Modifier-only bindings fire on release, use { run = ..., on = 'release' }",
            "[ERROR] mode.main.binding.cmd: Modifier-only bindings fire on release, use { run = ..., on = 'release' }",
            "[ERROR] mode.main.binding.ctrl: Modifier-only bindings fire on release, use { run = ..., on = 'release' }",
            "[ERROR] mode.main.binding.fn: Can't parse the key in 'fn' binding",
            "[ERROR] mode.main.binding.lalt: 'run' is mandatory",
            "[ERROR] mode.main.binding.lcmd.repeat: Modifier-only bindings can't repeat",
            "[ERROR] mode.main.binding.lctrl.run: Unrecognized subcommand 'foo'",
            "[ERROR] mode.main.binding.ralt: grab-and-move can only be triggered by a mouse binding (e.g. alt-leftMouse)",
            "[ERROR] mode.main.binding.rcmd.repeat: Modifier-only bindings can't repeat",
            "[ERROR] mode.main.binding.rshift: Modifier-only bindings fire on release, use { run = ..., on = 'release' }",
            "[ERROR] mode.main.binding.shift: Modifier-only bindings fire on release, use { run = ..., on = 'release' }",
        ])
        assertEquals(result.config.modes[mainModeId]?.modifierTapBindings, [:])
    }

    @Test func testConfigCommandPrintsModifierTapBindings() async {
        let result = parseConfig(
            """
            [mode.main.binding]
                rcmd = { run = 'focus right', on = 'release' }
            """,
        )
        assertEquals(result.errors, [])
        config = result.config
        let output = await parseCommand("config --get mode.main.binding.rcmd").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(output.exitCode.rawValue, 0)
        assertEquals(output.stdout, ["focus right"])
    }

    @Test func testTriggerBinding() async {
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(Window.get(byId: 2)?.focusWindow(), true)
        config.modes = [mainModeId: Mode(bindings: [:], modifierTapBindings: [
            "cmd": ModifierTapBinding(commands: parseCommand("focus left").cmdOrDie, descriptionWithKeyNotation: "cmd"),
        ])]

        let result = await parseCommand("trigger-binding cmd --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
    }

    private func dispatcher(_ recorder: Recorder, isSecureInputEnabled: Bool = false) -> ModifierTapDispatcher {
        ModifierTapDispatcher(isSecureInputEnabled: { isSecureInputEnabled }) { binding, mode in
            recorder.runs.append("\(mode):\(binding.descriptionWithKeyNotation)")
        }
    }

    private func setBindings(_ bindings: [String: [String]]) {
        let noop = parseCommand("true").cmdOrDie
        config.modes = bindings.mapValues { notations in
            Mode(bindings: [:], modifierTapBindings: Dictionary(uniqueKeysWithValues: notations.map {
                ($0, ModifierTapBinding(commands: noop, descriptionWithKeyNotation: $0))
            }))
        }
    }

    @Test func testDispatchRunsTheBindingOfTheActiveMode() async throws {
        setBindings([mainModeId: ["cmd", "ralt"], "launcher": ["cmd"]])
        let recorder = Recorder()
        let dispatcher = dispatcher(recorder)
        try await dispatcher.tapped(ModifierKey(name: "cmd", side: .left))?.value
        try await dispatcher.tapped(ModifierKey(name: "alt", side: .right))?.value
        assertNil(dispatcher.tapped(ModifierKey(name: "alt", side: .left)))
        assertNil(dispatcher.tapped(ModifierKey(name: "shift", side: .left)))
        activeMode = "launcher"
        try await dispatcher.tapped(ModifierKey(name: "cmd", side: .right))?.value
        assertEquals(recorder.runs, ["main:cmd", "main:ralt", "launcher:cmd"])
    }

    @Test func testDispatchDoesNothingWhileDisabledOrInSecureInput() {
        setBindings([mainModeId: ["cmd"]])
        let recorder = Recorder()
        assertNil(dispatcher(recorder, isSecureInputEnabled: true).tapped(ModifierKey(name: "cmd", side: .left)))
        activeMode = nil // What `hyprmac enable off` does
        assertNil(dispatcher(recorder).tapped(ModifierKey(name: "cmd", side: .left)))
        assertEquals(recorder.runs, [])
    }

    private func gate(_ recorder: Recorder, preflight: Bool, request: Bool = false) -> ListenEventAccessGate {
        ListenEventAccessGate(
            preflight: {
                recorder.preflightCalls += 1
                return preflight
            },
            request: {
                recorder.requestCalls += 1
                return request
            },
            report: { recorder.messages.append($0) },
        )
    }

    @Test func testPermissionRequestedOnceWithMessage() {
        let recorder = Recorder()
        let gate = gate(recorder, preflight: false)
        assertFalse(gate.hasAccess())
        assertFalse(gate.hasAccess())
        assertEquals(recorder.preflightCalls, 2)
        assertEquals(recorder.requestCalls, 1)
        assertEquals(recorder.messages, [listenEventAccessMessage])
    }

    @Test func testPermissionGrantedNeedsNoRequest() {
        let recorder = Recorder()
        assertTrue(gate(recorder, preflight: true).hasAccess())
        assertEquals(recorder.requestCalls, 0)
        assertEquals(recorder.messages, [])

        // The request can grant the access right away, then there is nothing to explain
        assertTrue(gate(recorder, preflight: false, request: true).hasAccess())
        assertEquals(recorder.requestCalls, 1)
        assertEquals(recorder.messages, [])
    }

    @Test func testTapKindWithoutModifierOnlyBindingsNeverChecksThePermission() {
        let recorder = Recorder()
        let gate = gate(recorder, preflight: false)
        assertEquals(
            desiredInputTapKind(isMouseGrabNeeded: true, isModifierTapNeeded: false, didKeyTapCreationFail: false, hasListenEventAccess: gate.hasAccess),
            InputTapKind(listensToKeys: false, hadListenEventAccess: false),
        )
        assertNil(desiredInputTapKind(isMouseGrabNeeded: false, isModifierTapNeeded: false, didKeyTapCreationFail: false, hasListenEventAccess: gate.hasAccess))
        assertEquals(recorder.preflightCalls, 0)
        assertEquals(recorder.messages, [])
    }

    @Test func testTapKindWithModifierOnlyBindings() {
        let recorder = Recorder()
        let gate = gate(recorder, preflight: false)
        assertEquals(
            desiredInputTapKind(isMouseGrabNeeded: false, isModifierTapNeeded: true, didKeyTapCreationFail: false, hasListenEventAccess: gate.hasAccess),
            InputTapKind(listensToKeys: true, hadListenEventAccess: false),
        )
        assertEquals(recorder.requestCalls, 1)
        assertEquals(recorder.messages.count, 1)
        // A failed keyboard tap falls back to the mouse-only tap, or to no tap at all
        assertEquals(
            desiredInputTapKind(isMouseGrabNeeded: true, isModifierTapNeeded: true, didKeyTapCreationFail: true, hasListenEventAccess: gate.hasAccess),
            InputTapKind(listensToKeys: false, hadListenEventAccess: false),
        )
        assertNil(desiredInputTapKind(isMouseGrabNeeded: false, isModifierTapNeeded: true, didKeyTapCreationFail: true, hasListenEventAccess: gate.hasAccess))
        // Granting the permission changes the kind, which restarts the tap
        assertEquals(
            desiredInputTapKind(isMouseGrabNeeded: false, isModifierTapNeeded: true, didKeyTapCreationFail: false, hasListenEventAccess: { true }),
            InputTapKind(listensToKeys: true, hadListenEventAccess: true),
        )
    }
}
