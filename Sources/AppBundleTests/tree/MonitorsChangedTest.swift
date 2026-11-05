@testable import AppBundle
import Common
import Foundation
import Testing

private struct FakeMonitorInfo: MonitorInfo {
    let monitorAppKitNsScreenScreensId = 1
    let name: String
    let rect: Rect
    let visibleRect: Rect
    let isMain = true
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }

    init(_ name: String, width: CGFloat, height: CGFloat, topLeftX: CGFloat = 0, menuBar: CGFloat = 40) {
        self.name = name
        self.rect = Rect(topLeftX: topLeftX, topLeftY: 0, width: width, height: height)
        self.visibleRect = Rect(topLeftX: topLeftX, topLeftY: menuBar, width: width, height: height - menuBar)
    }
}

private func cache(_ infos: [FakeMonitorInfo]) -> [CGPoint: MonitorInfo] {
    Dictionary(uniqueKeysWithValues: infos.map { ($0.rect.topLeftCorner, $0 as MonitorInfo) })
}

private let tempest = FakeMonitorInfo("Tempest 34'", width: 3440, height: 1440)
private let builtIn = FakeMonitorInfo("Built-in Retina Display", width: 1512, height: 982)

@Suite struct MonitorsChangedTest {
    @Test func sameMonitorsDoNotChange() {
        assertEquals(monitorsChanged(cached: cache([tempest]), current: [tempest]), false)
        assertEquals(monitorsChanged(cached: cache([builtIn, tempest.withX(1512)]), current: [builtIn, tempest.withX(1512)]), false)
    }

    @Test func pluggedOrUnpluggedMonitorChanges() {
        assertEquals(monitorsChanged(cached: cache([builtIn]), current: [builtIn, tempest.withX(1512)]), true)
        assertEquals(monitorsChanged(cached: cache([builtIn, tempest.withX(1512)]), current: [builtIn]), true)
    }

    @Test func monitorReplacedAtTheSamePositionChanges() {
        // The only external monitor is unplugged and the lid opens: still one monitor at (0, 0)
        assertEquals(monitorsChanged(cached: cache([tempest]), current: [builtIn]), true)
    }

    @Test func newResolutionOrVisibleAreaChanges() {
        let scaled = FakeMonitorInfo("Built-in Retina Display", width: 1728, height: 1117)
        assertEquals(monitorsChanged(cached: cache([builtIn]), current: [scaled]), true)
        let noMenuBar = FakeMonitorInfo("Built-in Retina Display", width: 1512, height: 982, menuBar: 0)
        assertEquals(monitorsChanged(cached: cache([builtIn]), current: [noMenuBar]), true)
    }
}

extension FakeMonitorInfo {
    fileprivate func withX(_ x: CGFloat) -> FakeMonitorInfo {
        FakeMonitorInfo(name, width: rect.width, height: rect.height, topLeftX: x, menuBar: rect.height - visibleRect.height)
    }
}
