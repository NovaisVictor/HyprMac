@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct SubscriptionSnapshotsTest {
    init() { setUpWorkspacesForTests() }

    @Test func testMovedWindowIsReported() {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        let window = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        let staying = TestWindow.new(id: 2, parent: a.rootTilingContainer)
        var snapshot: [OpaqueWindowId: String?] = [:]
        assertEquals(diffWindowWorkspaces([window, staying], &snapshot), [])

        window.bind(to: b.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(diffWindowWorkspaces([window, staying], &snapshot), [moved(1, "b", prev: "a")])
        assertEquals(diffWindowWorkspaces([window, staying], &snapshot), [])
    }

    @Test func testMovesAreReportedInWindowIdOrder() {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        let window2 = TestWindow.new(id: 2, parent: a.rootTilingContainer)
        let window1 = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        var snapshot: [OpaqueWindowId: String?] = [:]
        _ = diffWindowWorkspaces([window2, window1], &snapshot)

        window2.bind(to: b.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        window1.bind(to: b.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(diffWindowWorkspaces([window2, window1], &snapshot), [moved(1, "b", prev: "a"), moved(2, "b", prev: "a")])
    }

    @Test func testNewAndClosedWindowsAreNotReported() {
        let a = Workspace.get(byName: "a")
        let closed = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        var snapshot: [OpaqueWindowId: String?] = [:]
        _ = diffWindowWorkspaces([closed], &snapshot)

        closed.unbindFromParent()
        let new = TestWindow.new(id: 2, parent: a.rootTilingContainer)
        assertEquals(diffWindowWorkspaces([new], &snapshot), [])
        assertEquals(Array(snapshot.keys), [2])
    }

    @Test func testWindowMovedByOnWindowDetectedCallbackIsReported() {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        var snapshot: [OpaqueWindowId: String?] = [:]
        let window = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        // Emulates the snapshot entry that rememberDetectedWindowWorkspace records when window-detected is fired
        snapshot.updateValue("a", forKey: window.windowId)

        window.bind(to: b.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(diffWindowWorkspaces([window], &snapshot), [moved(1, "b", prev: "a")])
    }

    @Test func testMinimizedAndRestoredWindowsHaveNoWorkspace() {
        let a = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        defer { window.unbindFromParent() }
        var snapshot: [OpaqueWindowId: String?] = [:]
        _ = diffWindowWorkspaces([window], &snapshot)

        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(diffWindowWorkspaces([window], &snapshot), [moved(1, nil, prev: "a")])
        assertEquals(diffWindowWorkspaces([window], &snapshot), [])

        window.bind(to: a.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(diffWindowWorkspaces([window], &snapshot), [moved(1, "a", prev: nil)])
    }

    @Test func testPopupsAreNotReported() {
        let a = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: macosPopupWindowsContainer)
        defer { window.unbindFromParent() }
        var snapshot: [OpaqueWindowId: String?] = [:]
        _ = diffWindowWorkspaces([window], &snapshot)
        assertEquals(snapshot.count, 0)

        // A popup that turns out to be a window is reported by window-detected instead
        window.bind(to: a.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(diffWindowWorkspaces([window], &snapshot), [])

        window.bind(to: macosPopupWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(diffWindowWorkspaces([window], &snapshot), [])
        assertEquals(snapshot.count, 0)
    }

    @Test func testCurrentServerEventMonitors() {
        assertEquals(currentServerEventMonitors(), [ServerEventMonitor(monitorId: 1, monitorName: "Test Monitor")])
    }
}

@MainActor
private func moved(_ windowId: OpaqueWindowId, _ workspace: String?, prev prevWorkspace: String?) -> ServerEvent {
    .windowMoved(windowId: windowId, workspace: workspace, prevWorkspace: prevWorkspace, appBundleId: TestApp.shared.rawAppBundleId, appName: TestApp.shared.name)
}
