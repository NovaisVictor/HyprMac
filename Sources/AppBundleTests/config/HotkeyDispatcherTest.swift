@testable import AppBundle
import AppKit
import Common
import HotKey
import Testing

@MainActor
private final class Recorder {
    var delays: [Duration] = []
    var steps = 0
    var runs: [String] = []
    var repeater: KeyRepeater? = nil
}

private let testTiming = KeyRepeatTiming(delay: .milliseconds(500), interval: .milliseconds(30))

@MainActor
@Suite(.serializedGlobally)
struct HotkeyDispatcherTest {
    init() {
        setUpWorkspacesForTests()
        activeMode = mainModeId
    }

    @Test func testRepeaterWaitsDelayThenInterval() async {
        let recorder = Recorder()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let repeater = KeyRepeater(
                sleep: { delay in
                    recorder.delays.append(delay)
                    if recorder.delays.count == 4 {
                        recorder.repeater?.stop(key: "other")
                        assertFalse(Task.isCancelled) // Releasing another key mustn't stop the repeat
                        recorder.repeater?.stop(key: "alt-h")
                        continuation.resume()
                    }
                    try Task.checkCancellation()
                },
                timing: { testTiming },
            )
            recorder.repeater = repeater
            repeater.start(key: "alt-h") { recorder.steps += 1 }
        }
        assertEquals(recorder.delays, [.milliseconds(500), .milliseconds(30), .milliseconds(30), .milliseconds(30)])
        assertEquals(recorder.steps, 3)
        assertNil(recorder.repeater?.repeatingKey)
    }

    @Test func testRepeaterStepsDoNotStartAfterCancel() async {
        let recorder = Recorder()
        let repeater = KeyRepeater(sleep: { _ in await Task.yield() }, timing: { testTiming })
        repeater.start(key: "alt-h") {
            recorder.steps += 1
            if recorder.steps == 2 { repeater.cancel() }
        }
        while repeater.repeatingKey != nil { await Task.yield() }
        for _ in 0 ..< 10 { await Task.yield() }
        assertEquals(recorder.steps, 2)
    }

    private func dispatcher(_ recorder: Recorder, isStillHeld: Bool = true) -> HotkeyDispatcher {
        let repeater = KeyRepeater(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, timing: { testTiming })
        recorder.repeater = repeater
        return HotkeyDispatcher(repeater: repeater, isStillHeld: { _ in isStillHeld }) { binding, mode in
            recorder.runs.append("\(mode):\(binding.descriptionWithKeyNotation)")
        }
    }

    private func setBindings(_ bindings: [String: [HotkeyBinding]]) {
        config.modes = bindings.mapValues { Mode(bindings: Dictionary(uniqueKeysWithValues: $0.map { ($0.descriptionWithKeyCode, $0) })) }
    }

    private let noop: Shell<any Command> = parseCommand("true").cmdOrDie

    @Test func testPressBindingRunsOnKeyDownOnly() async throws {
        setBindings([mainModeId: [HotkeyBinding(.option, .h, noop)]])
        let recorder = Recorder()
        let dispatcher = dispatcher(recorder)
        try await dispatcher.keyDown("alt-h")?.value
        assertNil(dispatcher.keyUp("alt-h"))
        assertEquals(recorder.runs, ["main:alt-h"])
        assertNil(recorder.repeater?.repeatingKey)
    }

    @Test func testReleaseBindingRunsOnKeyUpOnly() async throws {
        setBindings([mainModeId: [HotkeyBinding(.option, .x, noop, trigger: .release, descriptionWithKeyNotation: "alt-x")]])
        let recorder = Recorder()
        let dispatcher = dispatcher(recorder)
        assertNil(dispatcher.keyDown("alt-x"))
        assertEquals(recorder.runs, [])
        try await dispatcher.keyUp("alt-x")?.value
        assertEquals(recorder.runs, ["main:alt-x"])

        // A key-up without a key-down (e.g. the key was pressed before the binding was enabled) does nothing
        assertNil(dispatcher.keyUp("alt-x"))
        assertEquals(recorder.runs, ["main:alt-x"])
    }

    @Test func testReleaseBindingIgnoresKeyPressedInAnotherMode() async throws {
        setBindings([
            mainModeId: [HotkeyBinding(.option, .x, noop)],
            "service": [HotkeyBinding(.option, .x, noop, trigger: .release, descriptionWithKeyNotation: "alt-x")],
        ])
        let recorder = Recorder()
        let dispatcher = dispatcher(recorder)
        try await dispatcher.keyDown("alt-x")?.value
        // What `alt-x = 'mode service'` does
        activeMode = "service"
        assertNil(dispatcher.keyUp("alt-x"))
        assertEquals(recorder.runs, ["main:alt-x"])
    }

    @Test func testRepeatBindingStartsOnKeyDownAndStopsOnKeyUp() async throws {
        setBindings([mainModeId: [HotkeyBinding(.option, .h, noop, repeats: true, descriptionWithKeyNotation: "alt-h")]])
        let recorder = Recorder()
        let dispatcher = dispatcher(recorder)
        let task = dispatcher.keyDown("alt-h")
        // The repeat starts synchronously, so that a key-up during the first run stops it
        assertEquals(recorder.repeater?.repeatingKey, "alt-h")
        try await task?.value
        assertEquals(recorder.runs, ["main:alt-h"])
        assertNil(dispatcher.keyUp("alt-h"))
        assertNil(recorder.repeater?.repeatingKey)
    }

    @Test func testCancelStopsRepeat() {
        setBindings([mainModeId: [HotkeyBinding(.option, .h, noop, repeats: true, descriptionWithKeyNotation: "alt-h")]])
        let recorder = Recorder()
        let dispatcher = dispatcher(recorder)
        dispatcher.keyDown("alt-h")
        assertEquals(recorder.repeater?.repeatingKey, "alt-h")
        dispatcher.cancel()
        assertNil(recorder.repeater?.repeatingKey)
    }

    @Test func testRepeatStopsWhenModifiersAreReleased() async {
        setBindings([mainModeId: [HotkeyBinding(.option, .h, noop, repeats: true, descriptionWithKeyNotation: "alt-h")]])
        let recorder = Recorder()
        let repeater = KeyRepeater(sleep: { _ in await Task.yield() }, timing: { testTiming })
        recorder.repeater = repeater
        let dispatcher = HotkeyDispatcher(repeater: repeater, isStillHeld: { _ in false }) { binding, mode in
            recorder.runs.append("\(mode):\(binding.descriptionWithKeyNotation)")
        }
        dispatcher.keyDown("alt-h")
        while repeater.repeatingKey != nil { await Task.yield() }
        for _ in 0 ..< 10 { await Task.yield() }
        assertEquals(recorder.runs, ["main:alt-h"]) // Only the press
    }
}
