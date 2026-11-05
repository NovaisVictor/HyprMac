@testable import AppBundle
import Common
import Testing

struct WindowTitleChangeDebouncerTest {
    private typealias Debouncer = WindowTitleChangeDebouncer<Int>
    private let t0 = ContinuousClock.now

    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    @Test func testTrailingDebounce() {
        var d = Debouncer()
        assertEquals(d.nextDeadline, nil)
        assertEquals(d.markChanged(1, now: at(0)), true)
        assertEquals(d.nextDeadline, at(300))
        assertEquals(d.takeDue(now: at(299)), [])

        // Another change of the same window postpones it, and doesn't need a wake-up
        assertEquals(d.markChanged(1, now: at(200)), false)
        assertEquals(d.nextDeadline, at(500))
        assertEquals(d.takeDue(now: at(300)), [])
        assertEquals(d.takeDue(now: at(500)), [1])
        assertEquals(d.nextDeadline, nil)
        assertEquals(d.takeDue(now: at(10000)), [])
    }

    @Test func testMaxDelay() {
        var d = Debouncer()
        for ms in stride(from: 0, through: 900, by: 100) {
            d.markChanged(1, now: at(ms))
        }
        // The trailing deadline would be 1200, but a window that never stops changing must not starve
        assertEquals(d.nextDeadline, at(1000))
        assertEquals(d.takeDue(now: at(1000)), [1])
    }

    @Test func testWindowsAreIndependent() {
        var d = Debouncer()
        d.markChanged(1, now: at(0))
        d.markChanged(2, now: at(100))
        d.markChanged(1, now: at(250)) // Postpones window 1 only
        assertEquals(d.nextDeadline, at(400))
        assertEquals(d.takeDue(now: at(400)), [2])
        assertEquals(d.takeDue(now: at(550)), [1])
    }

    @Test func testDueWindowsAreOrderedByTheFirstChange() {
        var d = Debouncer()
        d.markChanged(3, now: at(0))
        d.markChanged(1, now: at(10))
        d.markChanged(2, now: at(20))
        assertEquals(d.takeDue(now: at(1000)), [3, 1, 2])
    }

    @Test func testRateLimit() {
        var d = Debouncer()
        d.markChanged(1, now: at(0))
        assertEquals(d.takeDue(now: at(300)), [1])
        d.recordRun(1, now: at(300))

        d.markChanged(1, now: at(400))
        // Debounced by 700, but the callbacks of the window ran less than a second ago
        assertEquals(d.nextDeadline, at(1300))
        assertEquals(d.takeDue(now: at(700)), [])
        assertEquals(d.takeDue(now: at(1300)), [1])

        // Without a run, there's no limit
        d.markChanged(1, now: at(1400))
        assertEquals(d.takeDue(now: at(1700)), [1])
        d.markChanged(1, now: at(1800))
        assertEquals(d.takeDue(now: at(2100)), [1])
    }

    @Test func testForget() {
        var d = Debouncer()
        d.markChanged(1, now: at(0))
        d.recordRun(2, now: at(0))
        d.forget(1)
        d.forget(2)
        assertEquals(d.nextDeadline, nil)
        d.markChanged(2, now: at(100))
        assertEquals(d.nextDeadline, at(400)) // The run of the forgotten window doesn't limit it anymore
    }

    @Test func testRemoveAll() {
        var d = Debouncer()
        d.markChanged(1, now: at(0))
        d.recordRun(2, now: at(0))
        d.removeAll()
        assertEquals(d.nextDeadline, nil)
        d.markChanged(2, now: at(100))
        assertEquals(d.nextDeadline, at(400))
    }
}
