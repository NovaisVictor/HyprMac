@testable import AppBundle
import Common
import Foundation
import HotKey
import Testing

@MainActor
@Suite(.serializedGlobally)
struct ConfigCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        assertNil(parseCommand("config --major-keys").errorOrNil)
        assertNil(parseCommand("config --all-keys").errorOrNil)
        assertNil(parseCommand("config --config-path").errorOrNil)
        assertNil(parseCommand("config --get foo").errorOrNil)
        assertNil(parseCommand("config --get foo --keys").errorOrNil)
        assertNil(parseCommand("config --get foo --json").errorOrNil)
        assertNil(parseCommand("config --get foo --keys --json").errorOrNil)

        assertEquals(
            parseCommand("config").errorOrNil,
            "Mandatory flag is not specified (--get|--major-keys|--all-keys|--config-path)",
        )
        // --keys/--json alone still trigger the mandatory-flag check first because they don't
        // contribute to the mandatory-flag set.
        assertEquals(
            parseCommand("config --keys").errorOrNil,
            "Mandatory flag is not specified (--get|--major-keys|--all-keys|--config-path)",
        )
        assertEquals(
            parseCommand("config --json").errorOrNil,
            "Mandatory flag is not specified (--get|--major-keys|--all-keys|--config-path)",
        )
        assertEquals(parseCommand("config --major-keys --keys").errorOrNil, "--keys flag requires --get flag")
        assertEquals(parseCommand("config --major-keys --json").errorOrNil, "--json flag requires --get flag")

        // Two mandatory flags are mutually exclusive. The collection of conflicting flag names
        // comes from a Set so we can't rely on the order, only the message shape.
        let conflictErr = parseCommand("config --major-keys --all-keys").errorOrNil
        assertTrue(conflictErr?.hasPrefix("Conflicting flags are specified:") == true)
        assertTrue(conflictErr?.contains("--major-keys") == true)
        assertTrue(conflictErr?.contains("--all-keys") == true)
    }

    @Test func testConfigPath() async {
        let result = await parseCommand("config --config-path").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        assertEquals(result.stdout, [configUrl.absoluteURL.path])
    }

    @Test func testMajorKeys() async {
        config.modes = [
            "main": Mode(bindings: [:]),
            "service": Mode(bindings: [:]),
        ]
        let result = await parseCommand("config --major-keys").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        // The whole listing comes back as one stdout entry separated by newlines.
        // Dict iteration order isn't stable, so sort before asserting.
        let lines = (result.stdout.singleOrNil() ?? "").split(separator: "\n").map(String.init).sorted()
        assertEquals(lines, [".", "mode", "mode.main.binding", "mode.service.binding"])
    }

    @Test func testAllKeys() async {
        let command = parseCommand("focus left").cmdOrDie
        let binding = HotkeyBinding(.option, .h, command)
        config.modes = ["main": Mode(bindings: [binding.descriptionWithKeyCode: binding])]

        let result = await parseCommand("config --all-keys").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        // Dict iteration order isn't stable, so sort before asserting.
        let lines = (result.stdout.singleOrNil() ?? "").split(separator: "\n").map(String.init).sorted()
        assertEquals(lines, [
            ".",
            "animations",
            "animations.bezier",
            "animations.max-windows",
            "animations.mouse-grab",
            "animations.mouse-grab.curve",
            "animations.mouse-grab.duration-ms",
            "animations.mouse-grab.enabled",
            "animations.scratchpad",
            "animations.scratchpad.curve",
            "animations.scratchpad.direction",
            "animations.scratchpad.duration-ms",
            "animations.scratchpad.enabled",
            "animations.windows-move",
            "animations.windows-move.animate-size",
            "animations.windows-move.curve",
            "animations.windows-move.duration-ms",
            "animations.windows-move.enabled",
            "borders",
            "borders.active-color",
            "borders.angle-animation-period-ms",
            "borders.enabled",
            "borders.focus-pulse-ms",
            "borders.focus-sweep-ms",
            "borders.glow-color",
            "borders.glow-opacity",
            "borders.glow-radius",
            "borders.gradient-angle",
            "borders.inactive-color",
            "borders.order",
            "borders.radius",
            "borders.transition-ms",
            "borders.width",
            "master-new-window",
            "master-placement",
            "master-ratio-percent",
            "mode",
            "mode.main",
            "mode.main.binding",
            "mode.main.binding.alt-h",
            "mouse-grab",
            "mouse-grab.animation-duration-ms",
            "mouse-grab.ignore-app-ids",
            "mouse-grab.live-preview",
            "new-window-placement",
            "tab-bar",
            "tab-bar.active-color",
            "tab-bar.background-color",
            "tab-bar.enabled",
            "tab-bar.font-size",
            "tab-bar.gap",
            "tab-bar.height",
            "tab-bar.inactive-color",
            "tab-bar.show-icons",
            "tab-bar.text-color",
            "workspace",
        ])
    }

    @Test func testGetRoot_complexObject_fails() async {
        let result = await parseCommand("config --get .").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stdout, [])
        assertEquals(
            result.stderr,
            ["Complicated objects can be printed only with --json flag. Alternatively, you can try to inspect keys of the object with --keys flag"],
        )
    }

    @Test func testGetRoot_keys() async {
        config.modes = ["main": Mode(bindings: [:])]
        let result = await parseCommand("config --get . --keys").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        assertEquals(result.stdout, ["animations\nborders\nmaster-new-window\nmaster-placement\nmaster-ratio-percent\nmode\nmouse-grab\nnew-window-placement\ntab-bar\nworkspace"])
    }

    @Test func testGetRoot_json() async {
        config.modes = ["main": Mode(bindings: [:])]
        let expectedMap: ConfigMapValue = .map([
            "mode": .map(["main": .map(["binding": .map([:])])]),
            "new-window-placement": .scalar(.string("sibling")),
            "master-ratio-percent": .scalar(.int(55)),
            "master-new-window": .scalar(.string("after-focused")),
            "master-placement": .scalar(.string("start")),
            "mouse-grab": .map([
                "live-preview": .scalar(.bool(false)),
                "animation-duration-ms": .scalar(.int(150)),
                "ignore-app-ids": .array([]),
            ]),
            "workspace": .map([:]),
            "animations": .map([
                "max-windows": .scalar(.int(12)),
                "bezier": .map([:]),
                "windows-move": .map([
                    "enabled": .scalar(.bool(false)),
                    "duration-ms": .scalar(.int(150)),
                    "curve": .scalar(.string("ease-out")),
                    "animate-size": .scalar(.bool(true)),
                ]),
                "mouse-grab": .map([
                    "enabled": .scalar(.bool(true)),
                    "duration-ms": .scalar(.int(150)),
                    "curve": .scalar(.string("ease-out")),
                ]),
                "scratchpad": .map([
                    "enabled": .scalar(.bool(false)),
                    "duration-ms": .scalar(.int(200)),
                    "curve": .scalar(.string("ease-out")),
                    "direction": .scalar(.string("bottom")),
                ]),
            ]),
            "tab-bar": .map([
                "enabled": .scalar(.bool(false)),
                "height": .scalar(.int(24)),
                "font-size": .scalar(.int(12)),
                "show-icons": .scalar(.bool(true)),
                "gap": .scalar(.int(0)),
                "background-color": .scalar(.string("0xff1e1e2e")),
                "active-color": .scalar(.string("0xff89b4fa")),
                "inactive-color": .scalar(.string("0xff313244")),
                "text-color": .scalar(.string("0xffcdd6f4")),
            ]),
            "borders": .map([
                "enabled": .scalar(.bool(false)),
                "width": .scalar(.double(5)),
                "radius": .scalar(.string("auto")),
                "order": .scalar(.string("below")),
                "active-color": .scalar(.string("0xffb537f2")),
                "inactive-color": .scalar(.string("0xff45475a")),
                "gradient-angle": .scalar(.int(45)),
                "transition-ms": .scalar(.int(120)),
                "focus-sweep-ms": .scalar(.int(0)),
                "angle-animation-period-ms": .scalar(.int(0)),
                "glow-radius": .scalar(.double(0)),
                "glow-opacity": .scalar(.double(0.6)),
                "glow-color": .scalar(.string("")),
                "focus-pulse-ms": .scalar(.int(0)),
            ]),
        ])
        let expectedJson = JSONEncoder.hyprMacDefault.encodeToString(expectedMap)

        let result = await parseCommand("config --get . --json").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        assertEquals(result.stdout, [expectedJson])
    }

    @Test func testGetMap_keysJson() async {
        // --keys converts the map into an array of string-scalar keys, which is then JSON-encoded.
        let result = await parseCommand("config --get mouse-grab --keys --json").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        let keys = try? JSONDecoder().decode([String].self, from: Data((result.stdout.singleOrNil() ?? "").utf8))
        // Dict iteration order isn't stable
        assertEquals(keys?.sorted(), ["animation-duration-ms", "ignore-app-ids", "live-preview"])
    }

    @Test func testGetBorders() async {
        config.borders.activeColor = BorderPaint(colors: [ArgbColor(argb: 0xFFB5_37F2), ArgbColor(argb: 0xFF89_B4FA)]).orDie()
        config.borders.inactiveColor = nil
        let gradient = await parseCommand("config --get borders.active-color").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(gradient.stdout, ["0xff89b4fa\n0xffb537f2"]) // Plain arrays are printed sorted
        let gradientJson = await parseCommand("config --get borders.active-color --json").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(gradientJson.stdout.singleOrNil()?.filter { !$0.isWhitespace }, #"["0xffb537f2","0xff89b4fa"]"#)
        let noInactive = await parseCommand("config --get borders.inactive-color").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(noInactive.stdout, [""])
        let width = await parseCommand("config --get borders.width").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(width.stdout, ["5.0"])
        let autoRadius = await parseCommand("config --get borders.radius").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(autoRadius.stdout, ["auto"])
        config.borders.radius = .fixed(12)
        let fixedRadius = await parseCommand("config --get borders.radius").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(fixedRadius.stdout, ["12.0"])
    }

    @Test func testGetMode_keys_sortedOutput() async {
        config.modes = [
            "main": Mode(bindings: [:]),
            "service": Mode(bindings: [:]),
        ]
        let result = await parseCommand("config --get mode --keys").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        // Plain (non-json) array output is sorted before printing.
        assertEquals(result.stdout, ["main\nservice"])
    }

    @Test func testGetScalar() async {
        let command = parseCommand("focus left").cmdOrDie
        let binding = HotkeyBinding(.option, .h, command)
        config.modes = ["main": Mode(bindings: [binding.descriptionWithKeyCode: binding])]

        let result = await parseCommand("config --get mode.main.binding.alt-h").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        assertEquals(result.stdout, [command.shellOfCommandsDescription])
    }

    @Test func testGetForkKeys() async {
        let parsed = parseConfig(
            """
            new-window-placement = 'dwindle'
            master-ratio-percent = 60
            master-new-window = 'master'
            master-placement = [{ monitor.'Tempest' = 'center' }, 'start']
            [mouse-grab]
                live-preview = true
                animation-duration-ms = 200
                ignore-app-ids = ['com.figma.Desktop', 'com.apple.Terminal']
            """,
        )
        assertEquals(parsed.strErrors, [])
        config = parsed.config

        func get(_ args: String) async -> CmdResult {
            await parseCommand("config --get \(args)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
        assertEquals(await get("new-window-placement"), CmdResult(stdout: ["dwindle"], stderr: [], exitCode: Int32ExitCode(rawValue: 0)))
        assertEquals(await get("master-ratio-percent"), CmdResult(stdout: ["60"], stderr: [], exitCode: Int32ExitCode(rawValue: 0)))
        assertEquals(await get("master-new-window"), CmdResult(stdout: ["master"], stderr: [], exitCode: Int32ExitCode(rawValue: 0)))
        assertEquals(
            await get("master-placement --json"),
            CmdResult(
                stdout: ["[\n  {\n    \"monitor\" : {\n      \"Tempest\" : \"center\"\n    }\n  },\n  \"start\"\n]"],
                stderr: [],
                exitCode: Int32ExitCode(rawValue: 0),
            ),
        )
        assertEquals(await get("mouse-grab.live-preview"), CmdResult(stdout: ["true"], stderr: [], exitCode: Int32ExitCode(rawValue: 0)))
        assertEquals(await get("mouse-grab.animation-duration-ms"), CmdResult(stdout: ["200"], stderr: [], exitCode: Int32ExitCode(rawValue: 0)))
        assertEquals(await get("mouse-grab --keys"), CmdResult(stdout: ["animation-duration-ms\nignore-app-ids\nlive-preview"], stderr: [], exitCode: Int32ExitCode(rawValue: 0)))
        // Plain arrays are printed sorted
        assertEquals(await get("mouse-grab.ignore-app-ids"), CmdResult(stdout: ["com.apple.Terminal\ncom.figma.Desktop"], stderr: [], exitCode: Int32ExitCode(rawValue: 0)))
        assertEquals(
            await get("mouse-grab --json"),
            CmdResult(
                stdout: ["{\n  \"animation-duration-ms\" : 200,\n  \"ignore-app-ids\" : [\n    \"com.figma.Desktop\",\n    \"com.apple.Terminal\"\n  ],\n  \"live-preview\" : true\n}"],
                stderr: [],
                exitCode: Int32ExitCode(rawValue: 0),
            ),
        )
    }

    @Test func testGetWorkspaceRules() async {
        let parsed = parseConfig(
            """
            [workspace.G]
                default-root-container-layout = 'accordion'
                enable-normalization-flatten-containers = false
                gaps.outer.left = [{ monitor.main = 40 }, { monitor.'^dell' = 30 }, 20]
                gaps.inner.vertical = 5
            [workspace.H]
                new-window-placement = 'dwindle'
                master-new-window = 'stack-bottom'
            """,
        )
        assertEquals(parsed.strErrors, [])
        config = parsed.config

        func get(_ args: String) async -> CmdResult {
            await parseCommand("config --get \(args)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
        func succ(_ stdout: String) -> CmdResult { CmdResult(stdout: [stdout], stderr: [], exitCode: Int32ExitCode(rawValue: 0)) }
        assertEquals(await get("workspace --keys"), succ("G\nH"))
        // Only the keys that are set
        assertEquals(await get("workspace.G --keys"), succ("default-root-container-layout\nenable-normalization-flatten-containers\ngaps"))
        assertEquals(await get("workspace.G.default-root-container-layout"), succ("accordion"))
        assertEquals(await get("workspace.G.enable-normalization-flatten-containers"), succ("false"))
        assertEquals(await get("workspace.G.gaps.inner.vertical"), succ("5"))
        assertEquals(await get("workspace.G.gaps.outer --keys"), succ("left"))
        assertEquals(
            await get("workspace.G.gaps.outer.left --json"),
            succ("[\n  {\n    \"monitor\" : {\n      \"main\" : 40\n    }\n  },\n  {\n    \"monitor\" : {\n      \"^dell\" : 30\n    }\n  },\n  20\n]"),
        )
        assertEquals(await get("workspace.H.new-window-placement"), succ("dwindle"))
        assertEquals(await get("workspace.H.master-new-window"), succ("stack-bottom"))
    }

    @Test func testGetForkKeysDefaults() async {
        func get(_ key: String) async -> [String] {
            await parseCommand("config --get \(key)").cmdOrDie.run(.defaultEnv, .emptyStdin).stdout
        }
        assertEquals(await get("new-window-placement"), ["sibling"])
        assertEquals(await get("master-ratio-percent"), ["55"])
        assertEquals(await get("master-new-window"), ["after-focused"])
        assertEquals(await get("master-placement"), ["start"])
        assertEquals(await get("mouse-grab.live-preview"), ["false"])
        assertEquals(await get("mouse-grab.animation-duration-ms"), ["150"])
        assertEquals(await get("animations.max-windows"), ["12"])
        assertEquals(await get("animations.windows-move.enabled"), ["false"])
        assertEquals(await get("animations.mouse-grab.curve"), ["ease-out"])
        assertEquals(await get("animations.scratchpad.direction"), ["bottom"])
    }

    @Test func testGetAnimationKeys() async {
        let parsed = parseConfig(
            """
            [animations.windows-move]
                enabled = true
                curve = 'snappy'
            [animations.bezier]
                snappy = [0.05, 0.9, 0.1, 1.05]
            """,
        )
        assertEquals(parsed.strErrors, [])
        config = parsed.config

        func get(_ args: String) async -> [String] {
            await parseCommand("config --get \(args)").cmdOrDie.run(.defaultEnv, .emptyStdin).stdout
        }
        assertEquals(await get("animations.windows-move.enabled"), ["true"])
        assertEquals(await get("animations.windows-move.curve"), ["snappy"])
        assertEquals(await get("animations.bezier --keys"), ["snappy"])
        assertEquals(await get("animations.bezier.snappy --json"), ["[\n  0.05,\n  0.9,\n  0.1,\n  1.05\n]"])
    }

    @Test func testGetScalar_keys_fails() async {
        let command = parseCommand("focus left").cmdOrDie
        let binding = HotkeyBinding(.option, .h, command)
        config.modes = ["main": Mode(bindings: [binding.descriptionWithKeyCode: binding])]

        let result = await parseCommand("config --get mode.main.binding.alt-h --keys").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stdout, [])
        // The error message interpolates the enum directly, yielding the default Swift case repr.
        assertEquals(result.stderr, ["--keys flag cannot be applied to scalar object 'string(\"\(command.shellOfCommandsDescription)\")'"])
    }

    @Test func testGetScalar_dereference_fails() async {
        let command = parseCommand("focus left").cmdOrDie
        let binding = HotkeyBinding(.option, .h, command)
        config.modes = ["main": Mode(bindings: [binding.descriptionWithKeyCode: binding])]

        let result = await parseCommand("config --get mode.main.binding.alt-h.foo").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stdout, [])
        assertEquals(result.stderr, ["Can't dereference scalar value '\(command.shellOfCommandsDescription)'"])
    }

    @Test func testGetMissingKey_fails() async {
        let result = await parseCommand("config --get nonExistent").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stdout, [])
        assertEquals(result.stderr, ["No value at key token 'nonExistent'"])
    }

    @Test func testGetInvalidPath_emptyKey() async {
        let result = await parseCommand("config --get ''").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stdout, [])
        assertEquals(result.stderr, ["Invalid empty key"])
    }

    @Test func testGetInvalidPath_doubleDot() async {
        let result = await parseCommand("config --get a..b").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stdout, [])
        assertEquals(result.stderr, ["Invalid key 'a..b'"])
    }

    @Test func testGetInvalidPath_trailingDot() async {
        let result = await parseCommand("config --get a.").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stdout, [])
        assertEquals(result.stderr, ["Invalid key 'a.'"])
    }

    // The array branches of ConfigMapValue.find/dumpAllKeysRecursive are exercised directly here.
    @Test func testFindArrayIndex_success() {
        let arr: ConfigMapValue = .array([.scalar(.string("a")), .scalar(.string("b"))])
        switch arr.find(keyPath: ["1"].slice) {
            case .success(.scalar(.string(let s))): assertEquals(s, "b")
            default: Issue.record(Comment(rawValue: "expected .scalar(.string(\"b\"))"))
        }
    }

    @Test func testFindArrayIndex_outOfBounds() {
        let arr: ConfigMapValue = .array([.scalar(.string("a"))])
        assertFail(arr.find(keyPath: ["5"].slice), "Index out of bounds. Index: 5, Size: 1")
    }

    @Test func testFindArrayIndex_notInt() {
        let arr: ConfigMapValue = .array([.scalar(.string("a"))])
        assertFail(arr.find(keyPath: ["foo"].slice), "Can't convert key token 'foo' to Int")
    }

    @Test func testDumpAllKeys_array() {
        let value: ConfigMapValue = .array([.scalar(.string("a")), .map(["k": .scalar(.int(1))])])
        var result: [String] = []
        value.dumpAllKeysRecursive(path: ".", result: &result)
        assertEquals(result, [".", "0", "1", "1.k"])
    }
}
