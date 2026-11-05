@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct TreeCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        assertEquals(parseCommand("tree").errorOrNil, "Mandatory option is not specified (--workspace|--focused|--all)")
        assertEquals(parseCommand("tree --json").errorOrNil, "Mandatory option is not specified (--workspace|--focused|--all)")
        assertEquals(parseCommand("tree --all --focused").errorOrNil, "ERROR: Conflicting flags: --all, --focused")
        assertEquals(parseCommand("tree --all --workspace W").errorOrNil, "ERROR: Conflicting flags: --all, --workspace")
        assertEquals(parseCommand("tree --focused --workspace W").errorOrNil, "ERROR: Conflicting flags: --focused, --workspace")
        assertNil(parseCommand("tree --all").errorOrNil)
        assertNil(parseCommand("tree --focused --json").errorOrNil)
        assertNil(parseCommand("tree --workspace W").errorOrNil)
    }

    /// W: h_tiles [1 (focused), v_master [2, h_tiles (pinned orientation) [3 (pseudotiled), 4]]], floating [5 (scratchpad), 6 (pinned)]
    private func setUpNestedTree() {
        let workspace = Workspace.get(byName: "W")
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 2)
            TilingContainer(parent: $0, adaptiveWeight: 1, .v, .master, index: INDEX_BIND_LAST).apply {
                $0.masterRatio = 0.7
                TestWindow.new(id: 2, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1, index: INDEX_BIND_LAST).apply {
                    $0.hasPinnedOrientation = true
                    TestWindow.new(id: 3, parent: $0, adaptiveWeight: 3).isPseudoTiled = true
                    TestWindow.new(id: 4, parent: $0)
                }
            }
        }
        TestWindow.new(id: 5, parent: workspace.floatingWindowsContainer)
        scratchpadShownWindows[5] = ScratchpadHome(workspaceName: "S", wasFloating: true, prevFocusedWindowId: nil)
        TestWindow.new(id: 6, parent: workspace.floatingWindowsContainer)
        pinnedWindowIds.insert(6)
        assertEquals(Window.get(byId: 1)?.focusWindow(), true)
    }

    @Test func testJsonGolden() async {
        setUpNestedTree()
        let result = await parseCommand("tree --focused --json").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        assertEquals(result.stdout, [expectedJson])
    }

    @Test func testTextGolden() async {
        setUpNestedTree()
        let result = await parseCommand("tree --workspace W").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stderr, [])
        assertEquals(result.stdout, [
            "workspace W (monitor 1 'Test Monitor', focused, visible)",
            "├── h_tiles",
            "│   ├── window 1 | com.victornovais.HyprMac.test-app | TestWindow(1) (focused)",
            "│   └── v_master (master-ratio 0.7)",
            "│       ├── window 2 | com.victornovais.HyprMac.test-app | TestWindow(2)",
            "│       └── h_tiles (pinned orientation)",
            "│           ├── window 3 | com.victornovais.HyprMac.test-app | TestWindow(3) (pseudotiled)",
            "│           └── window 4 | com.victornovais.HyprMac.test-app | TestWindow(4)",
            "└── floating",
            "    ├── window 5 | com.victornovais.HyprMac.test-app | TestWindow(5) (scratchpad home 'S')",
            "    └── window 6 | com.victornovais.HyprMac.test-app | TestWindow(6) (pinned)",
        ])
    }

    @Test func testCenterMaster() async {
        let root = Workspace.get(byName: "W").rootTilingContainer
        root.layout = .master
        TestWindow.new(id: 1, parent: root)
        // By the monitor, the layout string stays h_master
        config.masterPlacement = .perMonitor([PerMonitorValue(description: .main, value: .center)], default: .start)
        let byMonitor = await parseCommand("tree --workspace W").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(byMonitor.stdout.getOrNil(atIndex: 1), "└── h_master (master-ratio 0.55, master-placement center)")

        config.masterPlacement = .constant(.start)
        root.masterPlacement = .center
        let byOverride = await parseCommand("tree --workspace W").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(byOverride.stdout.getOrNil(atIndex: 1), "└── h_center_master (master-ratio 0.55, master-placement center)")
    }

    @Test func testAllSeparatesWorkspaces() async {
        TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
        let result = await parseCommand("tree --all").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout.filter { $0.starts(with: "workspace ") || $0.isEmpty }, [
            "workspace a (monitor 1 'Test Monitor')",
            "",
            "workspace b (monitor 1 'Test Monitor')",
            "",
            "workspace setUpWorkspacesForTests (monitor 1 'Test Monitor', focused, visible)",
        ])
    }

    @Test func testMinimizedWindowsBelongToFocusedWorkspace() async {
        TestWindow.new(id: 1, parent: macosMinimizedWindowsContainer)
        let focused = await parseCommand("tree --focused").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focused.stdout, [
            "workspace setUpWorkspacesForTests (monitor 1 'Test Monitor', focused, visible)",
            "├── h_tiles",
            "└── macos-minimized",
            "    └── window 1 | com.victornovais.HyprMac.test-app | TestWindow(1)",
        ])
        let other = await parseCommand("tree --workspace W").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(other.stdout, [
            "workspace W (monitor 1 'Test Monitor')",
            "└── h_tiles",
        ])
    }

    @Test func testSkipsTombstones() async {
        let workspace = Workspace.get(byName: "W")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer).lifeStatus = .dead
        TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer).lifeStatus = .invisible
        let result = await parseCommand("tree --workspace W").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.stdout, [
            "workspace W (monitor 1 'Test Monitor')",
            "└── h_tiles",
            "    └── window 1 | com.victornovais.HyprMac.test-app | TestWindow(1)",
        ])
    }
}

private let expectedJson = """
    [
      {
        "floating-windows" : [
          {
            "app-bundle-id" : "com.victornovais.HyprMac.test-app",
            "app-name" : "com.victornovais.HyprMac.test-app",
            "app-pid" : 0,
            "is-focused" : false,
            "is-pinned" : false,
            "is-pseudotiled" : false,
            "scratchpad-home-workspace" : "S",
            "title" : "TestWindow(5)",
            "type" : "window",
            "window-id" : 5
          },
          {
            "app-bundle-id" : "com.victornovais.HyprMac.test-app",
            "app-name" : "com.victornovais.HyprMac.test-app",
            "app-pid" : 0,
            "is-focused" : false,
            "is-pinned" : true,
            "is-pseudotiled" : false,
            "title" : "TestWindow(6)",
            "type" : "window",
            "window-id" : 6
          }
        ],
        "hidden-app-windows" : [

        ],
        "is-focused" : true,
        "is-visible" : true,
        "macos-fullscreen-windows" : [

        ],
        "macos-minimized-windows" : [

        ],
        "monitor-id" : 1,
        "monitor-name" : "Test Monitor",
        "name" : "W",
        "root-container" : {
          "children" : [
            {
              "app-bundle-id" : "com.victornovais.HyprMac.test-app",
              "app-name" : "com.victornovais.HyprMac.test-app",
              "app-pid" : 0,
              "is-focused" : true,
              "is-pinned" : false,
              "is-pseudotiled" : false,
              "title" : "TestWindow(1)",
              "type" : "window",
              "weight" : 2,
              "window-id" : 1
            },
            {
              "children" : [
                {
                  "app-bundle-id" : "com.victornovais.HyprMac.test-app",
                  "app-name" : "com.victornovais.HyprMac.test-app",
                  "app-pid" : 0,
                  "is-focused" : false,
                  "is-pinned" : false,
                  "is-pseudotiled" : false,
                  "title" : "TestWindow(2)",
                  "type" : "window",
                  "weight" : 1,
                  "window-id" : 2
                },
                {
                  "children" : [
                    {
                      "app-bundle-id" : "com.victornovais.HyprMac.test-app",
                      "app-name" : "com.victornovais.HyprMac.test-app",
                      "app-pid" : 0,
                      "is-focused" : false,
                      "is-pinned" : false,
                      "is-pseudotiled" : true,
                      "title" : "TestWindow(3)",
                      "type" : "window",
                      "weight" : 3,
                      "window-id" : 3
                    },
                    {
                      "app-bundle-id" : "com.victornovais.HyprMac.test-app",
                      "app-name" : "com.victornovais.HyprMac.test-app",
                      "app-pid" : 0,
                      "is-focused" : false,
                      "is-pinned" : false,
                      "is-pseudotiled" : false,
                      "title" : "TestWindow(4)",
                      "type" : "window",
                      "weight" : 1,
                      "window-id" : 4
                    }
                  ],
                  "has-pinned-orientation" : true,
                  "layout" : "h_tiles",
                  "master-placement" : null,
                  "master-ratio" : null,
                  "orientation" : "horizontal",
                  "type" : "container",
                  "weight" : 1
                }
              ],
              "has-pinned-orientation" : false,
              "layout" : "v_master",
              "master-placement" : "start",
              "master-ratio" : 0.7,
              "orientation" : "vertical",
              "type" : "container",
              "weight" : 1
            }
          ],
          "has-pinned-orientation" : false,
          "layout" : "h_tiles",
          "master-placement" : null,
          "master-ratio" : null,
          "orientation" : "horizontal",
          "type" : "container",
          "weight" : 1920
        },
        "schema-version" : 1,
        "type" : "workspace"
      }
    ]
    """
