import Common
import Foundation

/// Decides when the windows whose title changed are processed. Pure, so the timing is testable with explicit instants
struct WindowTitleChangeDebouncer<Key: Hashable & Sendable>: Sendable {
    /// Trailing debounce: apps often set the title several times in a row (e.g. a browser that loads a page)
    static var debounce: Duration { .milliseconds(300) }
    /// A window whose title never stops changing (e.g. a terminal that shows a timer) would postpone the trailing debounce forever
    static var maxDelay: Duration { .seconds(1) }
    /// Callbacks that change the title of their own window, directly or through another app, must not spin in a loop
    static var minRunInterval: Duration { .seconds(1) }

    private struct Pending: Sendable {
        let firstChangeAt: ContinuousClock.Instant
        var lastChangeAt: ContinuousClock.Instant
    }

    private var pending: [Key: Pending] = [:]
    private var lastRunAt: [Key: ContinuousClock.Instant] = [:]

    /// Returns true if the window wasn't pending yet. Otherwise, its deadline only moves later,
    /// so whoever waits for ``nextDeadline`` doesn't need to be woken up
    @discardableResult
    mutating func markChanged(_ key: Key, now: ContinuousClock.Instant) -> Bool {
        if pending[key] != nil {
            pending[key]?.lastChangeAt = now
            return false
        }
        pending[key] = Pending(firstChangeAt: now, lastChangeAt: now)
        return true
    }

    var nextDeadline: ContinuousClock.Instant? {
        pending.keys.map(deadline(of:)).min()
    }

    /// Removes and returns the windows that are due, the ones that changed first go first
    mutating func takeDue(now: ContinuousClock.Instant) -> [Key] {
        let due = pending.filter { deadline(of: $0.key) <= now }.sorted { $0.value.firstChangeAt < $1.value.firstChangeAt }
        for (key, _) in due {
            pending.removeValue(forKey: key)
        }
        // The expired entries no longer limit anything. Dropping them keeps the dictionary from growing with every window
        lastRunAt = lastRunAt.filter { now < $0.value + Self.minRunInterval }
        return due.map(\.key)
    }

    mutating func recordRun(_ key: Key, now: ContinuousClock.Instant) {
        lastRunAt[key] = now
    }

    mutating func forget(_ key: Key) {
        pending.removeValue(forKey: key)
        lastRunAt.removeValue(forKey: key)
    }

    mutating func removeAll() {
        pending = [:]
        lastRunAt = [:]
    }

    private func deadline(of key: Key) -> ContinuousClock.Instant {
        let p = pending[key].orDie()
        let debounced = min(p.lastChangeAt + Self.debounce, p.firstChangeAt + Self.maxDelay)
        guard let lastRunAt = lastRunAt[key] else { return debounced }
        return max(debounced, lastRunAt + Self.minRunInterval)
    }
}
