@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct TabBarConfigTest {
    init() { setUpWorkspacesForTests() }

    @Test func testDefaults() {
        let tabBar = defaultConfig.tabBar
        assertEquals(tabBar, TabBarConfig())
        assertEquals(tabBar.enabled, false)
        assertEquals(tabBar.height, 24)
        assertEquals(tabBar.gap, 0)
        assertEquals(tabBar.reservedHeight, 0)
        assertEquals(tabBar.backgroundColor, ArgbColor(0xFF1E_1E2E))
    }

    @Test func testParse() {
        let result = parseConfig(
            """
            [tab-bar]
                enabled = true
                height = 30
                font-size = 14
                show-icons = false
                gap = 4
                background-color = '0x80000000'
                active-color = '0XFFFFFFFF'
                inactive-color = '0xff00FF00'
                text-color = '0x00000001'
            """,
        )
        assertEquals(result.errors, [])
        let tabBar = result.config.tabBar
        assertEquals(tabBar.enabled, true)
        assertEquals(tabBar.height, 30)
        assertEquals(tabBar.fontSize, 14)
        assertEquals(tabBar.showIcons, false)
        assertEquals(tabBar.gap, 4)
        assertEquals(tabBar.reservedHeight, 34)
        assertEquals(tabBar.backgroundColor, ArgbColor(0x8000_0000))
        assertEquals(tabBar.activeColor, ArgbColor(0xFFFF_FFFF))
        assertEquals(tabBar.inactiveColor, ArgbColor(0xFF00_FF00))
        assertEquals(tabBar.textColor, ArgbColor(0x0000_0001))
    }

    @Test func testColorComponents() {
        let color = ArgbColor(0x80FF_0033)
        assertEquals(color.alpha, 128.0 / 255)
        assertEquals(color.red, 1)
        assertEquals(color.green, 0)
        assertEquals(color.blue, 0.2)
        assertEquals(color.description, "0x80ff0033")
        assertEquals(ArgbColor(0x0000_00AB).description, "0x000000ab")
    }

    @Test func testParseErrors() {
        let colorError = "Expected format: '0xAARRGGBB' (alpha, red, green, blue)"
        for bad in ["ff89b4fa", "0x89b4fa", "0xff89b4fa0", "0xgg89b4fa", "0x+f89b4fa", "#ff89b4fa", ""] {
            assertEquals(
                parseConfig("tab-bar.active-color = '\(bad)'").strErrors,
                ["[ERROR] tab-bar.active-color: Can't parse color '\(bad)'. \(colorError)"],
            )
        }
        // The same color parser as [borders]: the bare TOML hex integer is accepted too
        let bareInt = parseConfig("tab-bar.text-color = 0xff89b4fa")
        assertEquals(bareInt.strErrors, [])
        assertEquals(bareInt.config.tabBar.textColor, ArgbColor(0xFF89_B4FA))
        assertEquals(parseConfig("tab-bar.height = 0").strErrors, ["[ERROR] tab-bar.height: height must be in [1, 100] range"])
        assertEquals(parseConfig("tab-bar.font-size = 73").strErrors, ["[ERROR] tab-bar.font-size: font-size must be in [1, 72] range"])
        assertEquals(parseConfig("tab-bar.gap = -1").strErrors, ["[ERROR] tab-bar.gap: gap must be in [0, 100] range"])
        assertEquals(parseConfig("tab-bar.unknown = 1").strErrors, ["[ERROR] tab-bar.unknown: Unknown key"])
    }

    @Test func testConfigGet() async {
        config.tabBar = TabBarConfig(enabled: true, height: 30, activeColor: ArgbColor(0xFF00_0000))
        let enabled = await parseCommand("config --get tab-bar.enabled").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(enabled.stdout, ["true"])
        let height = await parseCommand("config --get tab-bar.height").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(height.stdout, ["30"])
        let color = await parseCommand("config --get tab-bar.active-color").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(color.stdout, ["0xff000000"])
        let keys = await parseCommand("config --get tab-bar --keys").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(keys.stdout, [
            [
                "active-color", "background-color", "enabled", "font-size", "gap", "height", "inactive-color", "show-icons", "text-color",
            ].joined(separator: "\n"),
        ])
    }
}
