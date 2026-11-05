@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct BordersConfigTest {
    init() { setUpWorkspacesForTests() }

    @Test func testDefaults() {
        let borders = defaultConfig.borders
        assertEquals(borders, BordersConfig())
        assertEquals(borders.enabled, false)
        assertEquals(borders.width, 5)
        assertEquals(borders.radius, .auto)
        assertEquals(borders.order, .below)
        assertEquals(borders.activeColor, BorderPaint(ArgbColor(argb: 0xFFB5_37F2)))
        assertEquals(borders.inactiveColor, BorderPaint(ArgbColor(argb: 0xFF45_475A)))
        assertEquals(borders.gradientAngle, 45)
        assertEquals(borders.transitionMs, 120)
        assertEquals(borders.focusSweepMs, 0)
        assertEquals(borders.angleAnimationPeriodMs, 0)
        assertEquals(borders.glowRadius, 0)
        assertEquals(borders.glowOpacity, 0.6)
        assertNil(borders.glowColor)
        assertEquals(borders.focusPulseMs, 0)
    }

    @Test func testParseFullTable() {
        let result = parseConfig(
            """
            [borders]
                enabled = true
                width = 2.5
                radius = 12
                active-color = ['0xffb537f2', '0xFF89B4FA']
                inactive-color = 0xff45475a
                gradient-angle = -90
                transition-ms = 0
                focus-sweep-ms = 400
                angle-animation-period-ms = 3000
                glow-radius = 12.5
                glow-opacity = 0.8
                glow-color = '0x80cba6f7'
                focus-pulse-ms = 300
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.warnings.filter { $0.backtrace.description.hasPrefix("borders") }, [])
        let borders = result.config.borders
        assertEquals(borders.enabled, true)
        assertEquals(borders.width, 2.5)
        assertEquals(borders.radius, .fixed(12))
        assertEquals(borders.activeColor.colors, [ArgbColor(argb: 0xFFB5_37F2), ArgbColor(argb: 0xFF89_B4FA)])
        assertEquals(borders.activeColor.isGradient, true)
        assertEquals(borders.inactiveColor, BorderPaint(ArgbColor(argb: 0xFF45_475A)))
        assertEquals(borders.gradientAngle, -90)
        assertEquals(borders.transitionMs, 0)
        assertEquals(borders.focusSweepMs, 400)
        assertEquals(borders.angleAnimationPeriodMs, 3000)
        assertEquals(borders.glowRadius, 12.5)
        assertEquals(borders.glowOpacity, 0.8)
        assertEquals(borders.glowColor, ArgbColor(argb: 0x80CB_A6F7))
        assertEquals(borders.focusPulseMs, 300)
    }

    @Test func testOrder() {
        let above = parseConfig("borders.order = 'above'")
        assertEquals(above.strErrors, [])
        assertEquals(above.config.borders.order, .above)
        assertEquals(
            parseConfig("borders.order = 'top'").strErrors,
            ["[ERROR] borders.order: Can't parse border order 'top'. Possible values: below, above"],
        )
    }

    @Test func testGlowOptions() {
        assertEquals(parseConfig("borders.glow-radius = 50").config.borders.glowRadius, 50)
        assertEquals(parseConfig("borders.glow-opacity = 1").config.borders.glowOpacity, 1)
        assertEquals(parseConfig("borders.glow-opacity = 0").config.borders.glowOpacity, 0)
        assertNil(parseConfig("borders.glow-color = ''").config.borders.glowColor)
        assertEquals(parseConfig("borders.glow-color = 0xff89b4fa").config.borders.glowColor, ArgbColor(argb: 0xFF89_B4FA))
        assertEquals(parseConfig("borders.glow-radius = -1").strErrors, ["[ERROR] borders.glow-radius: glow-radius must be in [0, 50] range"])
        assertEquals(parseConfig("borders.glow-radius = 50.5").strErrors, ["[ERROR] borders.glow-radius: glow-radius must be in [0, 50] range"])
        assertEquals(parseConfig("borders.glow-opacity = 1.1").strErrors, ["[ERROR] borders.glow-opacity: glow-opacity must be in [0, 1] range"])
        assertEquals(parseConfig("borders.glow-opacity = '0.5'").strErrors, [
            "[ERROR] borders.glow-opacity: Expected types are 'int' or 'float'. But actual type is 'string'",
        ])
        assertEquals(parseConfig("borders.focus-pulse-ms = 2001").strErrors, ["[ERROR] borders.focus-pulse-ms: focus-pulse-ms must be in [0, 2000] range"])
        assertEquals(parseConfig("borders.focus-pulse-ms = -1").strErrors, ["[ERROR] borders.focus-pulse-ms: focus-pulse-ms must be in [0, 2000] range"])
        // A glow has one color: a gradient isn't a glow color
        assertEquals(parseConfig("borders.glow-color = ['0xff000000', '0xffffffff']").strErrors, [
            "[ERROR] borders.glow-color: Expected types are 'string' or 'int'. But actual type is 'array'",
        ])
        assertEquals(parseConfig("borders.glow-color = 'red'").strErrors, [
            "[ERROR] borders.glow-color: Can't parse color 'red'. Expected format: '0xAARRGGBB' (alpha, red, green, blue)",
        ])
    }

    @Test func testFocusPulseWarnsWithoutGlow() {
        let withoutGlow = parseConfig(
            """
            config-version = 2
            borders.focus-pulse-ms = 300
            """,
        )
        assertEquals(withoutGlow.errors, [])
        assertEquals(withoutGlow.strWarnings, ["[WARNING] borders.focus-pulse-ms: Has no effect: glow-radius is 0, the glow is disabled"])

        let withGlow = parseConfig(
            """
            config-version = 2
            borders.focus-pulse-ms = 300
            borders.glow-radius = 10
            """,
        )
        assertEquals(withGlow.errors, [])
        assertEquals(withGlow.strWarnings, [])
    }

    @Test func testEmptyInactiveColorDisablesInactiveBorders() {
        let result = parseConfig("borders.inactive-color = ''")
        assertEquals(result.errors, [])
        assertNil(result.config.borders.inactiveColor)
    }

    @Test func testSingleColorArrayIsSolid() {
        let result = parseConfig("borders.active-color = ['0x80ff0000']")
        assertEquals(result.errors, [])
        assertEquals(result.config.borders.activeColor.isGradient, false)
    }

    @Test func testColorErrors() {
        let format = "Expected format: '0xAARRGGBB' (alpha, red, green, blue)"
        assertEquals(parseConfig("borders.active-color = '0xff0000'").strErrors, [
            "[ERROR] borders.active-color: Can't parse color '0xff0000'. \(format)",
        ])
        assertEquals(parseConfig("borders.active-color = '#ffb537f2'").strErrors, [
            "[ERROR] borders.active-color: Can't parse color '#ffb537f2'. \(format)",
        ])
        assertEquals(parseConfig("borders.active-color = '0xffb537fg'").strErrors, [
            "[ERROR] borders.active-color: Can't parse color '0xffb537fg'. \(format)",
        ])
        assertEquals(parseConfig("borders.active-color = ''").strErrors, [
            "[ERROR] borders.active-color: active-color can't be empty",
        ])
        assertEquals(parseConfig("borders.active-color = []").strErrors, [
            "[ERROR] borders.active-color: A gradient needs at least one color",
        ])
        assertEquals(parseConfig("borders.inactive-color = ['0xff000000', 'red']").strErrors, [
            "[ERROR] borders.inactive-color[1]: Can't parse color 'red'. \(format)",
        ])
        assertEquals(parseConfig("borders.active-color = 0x1ffffffff").strErrors, [
            "[ERROR] borders.active-color: Can't parse color '8589934591'. \(format)",
        ])
        assertEquals(parseConfig("borders.active-color = true").strErrors, [
            "[ERROR] borders.active-color: Expected types are 'string' or 'int'. But actual type is 'bool'",
        ])
    }

    @Test func testRangeErrors() {
        assertEquals(parseConfig("borders.width = 0").strErrors, ["[ERROR] borders.width: width must be in [1, 50] range"])
        assertEquals(parseConfig("borders.width = 50.5").strErrors, ["[ERROR] borders.width: width must be in [1, 50] range"])
        assertEquals(parseConfig("borders.gradient-angle = 361").strErrors, ["[ERROR] borders.gradient-angle: gradient-angle must be in [-360, 360] range"])
        assertEquals(parseConfig("borders.transition-ms = 1001").strErrors, ["[ERROR] borders.transition-ms: transition-ms must be in [0, 1000] range"])
        assertEquals(parseConfig("borders.focus-sweep-ms = 5001").strErrors, ["[ERROR] borders.focus-sweep-ms: focus-sweep-ms must be in [0, 5000] range"])
        assertEquals(parseConfig("borders.angle-animation-period-ms = 100").strErrors, [
            "[ERROR] borders.angle-animation-period-ms: angle-animation-period-ms must be 0 (disabled) or in [250, 600000] range",
        ])
        assertEquals(parseConfig("borders.width = '5'").strErrors, ["[ERROR] borders.width: Expected types are 'int' or 'float'. But actual type is 'string'"])
        assertEquals(parseConfig("borders.unknown = 1").strErrors, ["[ERROR] borders.unknown: Unknown key"])
    }

    @Test func testRadius() {
        assertEquals(parseConfig("borders.radius = 'auto'").config.borders.radius, .auto)
        assertEquals(parseConfig("borders.radius = 0").config.borders.radius, .fixed(0))
        assertEquals(parseConfig("borders.radius = 12.5").config.borders.radius, .fixed(12.5))
        assertEquals(parseConfig("borders.radius = 100").config.borders.radius, .fixed(100))
        let rangeError = "[ERROR] borders.radius: radius must be 'auto' or in [0, 100] range"
        assertEquals(parseConfig("borders.radius = -1").strErrors, [rangeError])
        assertEquals(parseConfig("borders.radius = 100.5").strErrors, [rangeError])
        assertEquals(parseConfig("borders.radius = 'Auto'").strErrors, [rangeError])
        assertEquals(parseConfig("borders.radius = '12'").strErrors, [rangeError])
        assertEquals(parseConfig("borders.radius = true").strErrors, [
            "[ERROR] borders.radius: Expected types are 'string' or 'int' or 'float'. But actual type is 'bool'",
        ])
    }

    @Test func testAngleOptionsWarnWithSolidActiveColor() {
        let result = parseConfig(
            """
            config-version = 2
            borders.focus-sweep-ms = 300
            borders.angle-animation-period-ms = 2000
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.strWarnings.sorted(), [
            "[WARNING] borders.angle-animation-period-ms: Has no effect: active-color is a solid color, not a gradient",
            "[WARNING] borders.focus-sweep-ms: Has no effect: active-color is a solid color, not a gradient",
        ])
    }

    @Test func testParseArgbColor() {
        let color = parseArgbColor("0x80FF4000").orDie()
        assertEquals(color.alpha, 128.0 / 255)
        assertEquals(color.red, 1)
        assertEquals(color.green, 64.0 / 255)
        assertEquals(color.blue, 0)
        assertEquals(color.hexDescription, "0x80ff4000")
        assertNil(parseArgbColor("0x80FF40001"))
        assertNil(parseArgbColor("0x+0FF4000"))
        assertNil(parseArgbColor("ff80FF4000"))
    }
}
