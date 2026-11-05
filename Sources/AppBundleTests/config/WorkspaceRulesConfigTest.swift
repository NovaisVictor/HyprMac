@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct WorkspaceRulesConfigTest {
    @Test func testDefaultIsEmpty() {
        assertEquals(parseConfig("").config.workspaceRules, [:])
        assertEquals(defaultConfig.workspaceRules, [:])
    }

    @Test func testParseAllKeys() {
        let result = parseConfig(
            """
            [workspace.G]
                default-root-container-layout = 'accordion'
                default-root-container-orientation = 'horizontal'
                enable-normalization-flatten-containers = false
                enable-normalization-opposite-orientation-for-nested-containers = false
                new-window-placement = 'dwindle'
                gaps.inner.vertical = 5
                gaps.outer.left = [{ monitor.main = 40 }, 20]
            [workspace.NeverCreated]
                new-window-placement = 'sibling'
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.workspaceRules, [
            "G": WorkspaceRule(
                defaultRootContainerLayout: .accordion,
                defaultRootContainerOrientation: .horizontal,
                enableNormalizationFlattenContainers: false,
                enableNormalizationOppositeOrientationForNestedContainers: false,
                newWindowPlacement: .dwindle,
                gaps: GapsOverride(
                    inner: .init(vertical: .constant(5)),
                    outer: .init(left: .perMonitor([PerMonitorValue(description: .main, value: 40)], default: 20)),
                ),
            ),
            "NeverCreated": WorkspaceRule(newWindowPlacement: .sibling),
        ])
    }

    @Test func testGapsOverrideInheritsGlobalGaps() {
        let global = Gaps(
            inner: .init(vertical: 1, horizontal: 2),
            outer: .init(left: 3, bottom: 4, top: 5, right: 6),
        )
        let override = GapsOverride(
            inner: .init(horizontal: .constant(20)),
            outer: .init(left: .constant(30), right: .perMonitor([PerMonitorValue(description: .secondary, value: 7)], default: 60)),
        )
        assertEquals(
            override.applied(to: global),
            Gaps(
                inner: .init(vertical: .constant(1), horizontal: .constant(20)),
                outer: .init(
                    left: .constant(30),
                    bottom: .constant(4),
                    top: .constant(5),
                    right: .perMonitor([PerMonitorValue(description: .secondary, value: 7)], default: 60),
                ),
            ),
        )
        assertEquals(GapsOverride().applied(to: global), global)
    }

    @Test func testUnknownKeys() {
        let result = parseConfig(
            """
            [workspace.G]
                accordion-padding = 10
                gaps.outer.middle = 1
            """,
        )
        assertEquals(result.strErrors.sorted(), [
            "[ERROR] workspace.G.accordion-padding: Unknown key",
            "[ERROR] workspace.G.gaps.outer.middle: Unknown key",
        ])
    }

    @Test func testInvalidValues() {
        let result = parseConfig(
            """
            [workspace.G]
                default-root-container-layout = 'spiral'
                default-root-container-orientation = 'diagonal'
                enable-normalization-flatten-containers = 'no'
                new-window-placement = 'spiral'
                gaps.inner.vertical = 'wide'
            """,
        )
        assertEquals(result.strErrors.sorted(), [
            "[ERROR] workspace.G.default-root-container-layout: Can't parse layout 'spiral'",
            "[ERROR] workspace.G.default-root-container-orientation: Can't parse default container orientation 'diagonal'",
            "[ERROR] workspace.G.enable-normalization-flatten-containers: Expected type is 'Bool'. But actual type is 'String'",
            "[ERROR] workspace.G.gaps.inner.vertical: Unsupported type: string, expected: Int or array",
            "[ERROR] workspace.G.new-window-placement: Can't parse new window placement 'spiral'. Possible values: sibling, dwindle",
        ])
        assertEquals(result.config.workspaceRules["G"], WorkspaceRule(gaps: GapsOverride(inner: .init(vertical: .constant(0)))))
    }

    @Test func testWrongTypes() {
        assertEquals(
            parseConfig("workspace = 1").strErrors,
            ["[ERROR] workspace: Expected type is 'Table'. But actual type is 'Int'"],
        )
        assertEquals(
            parseConfig("workspace.G = 1").strErrors,
            ["[ERROR] workspace.G: Expected type is 'Table'. But actual type is 'Int'"],
        )
        assertEquals(
            parseConfig("[workspace.G]").strErrors,
            ["[ERROR] workspace.G: empty table is not allowed here"],
        )
    }

    @Test func testSplitIsAllowedWhenSomeWorkspaceDisablesFlatten() {
        let result = parseConfig(
            """
            enable-normalization-flatten-containers = true
            [mode.main.binding]
                alt-s = 'split horizontal'
            [workspace.G]
                enable-normalization-flatten-containers = false
            """,
        )
        assertEquals(result.errors, [])

        let enabledEverywhere = parseConfig(
            """
            enable-normalization-flatten-containers = true
            [mode.main.binding]
                alt-s = 'split horizontal'
            [workspace.G]
                enable-normalization-flatten-containers = true
            """,
        )
        assertEquals(enabledEverywhere.errors.count, 1)
    }
}
