import AppKit
import Common
import os

// Every frame the animator writes comes back as AX moved/resized notifications. Without this filter each of them
// schedules a complete refresh session (up to 60 per second per animated window), and while the left button is down
// the native drag detection mistakes them for the user dragging the focused window.
// The AX observers run on the app threads, so the check happens there, before any MainActor hop

struct AnimationEchoKey: Hashable, Sendable {
    // periphery:ignore - false positive unused warning. The properties are only read through Hashable
    let pid: pid_t
    // periphery:ignore - false positive unused warning. The properties are only read through Hashable
    let nativeWindowId: UInt32
}

/// The notification of the last frame can arrive a bit after the write, especially for slow apps
let animationEchoGracePeriod: Duration = .milliseconds(150)

/// Deadlines until which AX notifications of the window are considered echoes of our own animated writes
private let animationEchoDeadlines = OSAllocatedUnfairLock<[AnimationEchoKey: ContinuousClock.Instant]>(initialState: [:])

func markAnimationEcho(_ key: AnimationEchoKey, now: ContinuousClock.Instant = .now) {
    animationEchoDeadlines.withLock { $0[key] = now + animationEchoGracePeriod }
}

func isAnimationEcho(_ key: AnimationEchoKey, now: ContinuousClock.Instant = .now) -> Bool {
    animationEchoDeadlines.withLock { deadlines in
        guard let deadline = deadlines[key] else { return false }
        if now < deadline { return true }
        deadlines.removeValue(forKey: key)
        return false
    }
}
