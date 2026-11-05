import AppKit
import Common

struct KeyRepeatTiming: Equatable {
    let delay: Duration
    let interval: Duration

    /// Read on every key press, so that changes in System Settings apply without a restart
    @MainActor static var system: KeyRepeatTiming {
        KeyRepeatTiming(delay: .seconds(NSEvent.keyRepeatDelay), interval: .seconds(NSEvent.keyRepeatInterval))
    }
}

/// Repeats `repeat = true` bindings while their key is held.
/// Carbon hotkeys (HotKey library) fire only once per press, so the repeat is driven by our own timer
@MainActor
final class KeyRepeater {
    private let sleep: @MainActor (Duration) async throws -> Void
    private let timing: @MainActor () -> KeyRepeatTiming
    private var current: (key: String, task: Task<Void, Never>)?

    init(
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        timing: @escaping @MainActor () -> KeyRepeatTiming = { .system },
    ) {
        self.sleep = sleep
        self.timing = timing
    }

    /// The first step runs after the key repeat delay, then every key repeat interval, until ``stop(key:)`` or ``cancel()``.
    /// The press itself isn't a step: the caller runs it
    func start(key: String, step: @escaping @MainActor () async -> Void) {
        cancel()
        let timing = timing()
        let sleep = sleep
        current = (key, Task.startUnstructured {
            var delay = timing.delay
            while !Task.isCancelled {
                do {
                    try await sleep(delay)
                } catch {
                    // Sleep throws only on cancellation, which is how the repeat is stopped
                    return
                }
                if Task.isCancelled { return }
                await step()
                delay = timing.interval
            }
        })
    }

    /// Stops the repeat only if it was started by `key`: releasing another key mustn't stop it
    func stop(key: String) {
        if current?.key == key { cancel() }
    }

    func cancel() {
        current?.task.cancel()
        current = nil
    }

    var repeatingKey: String? { current?.key }
}
