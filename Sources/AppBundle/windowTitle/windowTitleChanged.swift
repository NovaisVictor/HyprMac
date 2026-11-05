import AppKit
import Common
import os

// on-window-title-changed callbacks and the window-title-changed event.
//
// The AX observer only marks the window as changed. The title is re-read when the debounce fires: the payload of the
// notification isn't trusted (https://github.com/nikitabobko/AeroSpace/issues/1519), and the title often changes several
// times in a row. The callbacks are edge triggered: a callback runs when its `if` starts matching the window, not
// every time the title changes while it matches

struct WindowTitleKey: Hashable, Sendable {
    let pid: pid_t
    let nativeWindowId: UInt32
}

/// Read by the AX threads, before any MainActor hop
private let windowTitleObservationEnabled = OSAllocatedUnfairLock(initialState: false)
private let titleChangeDebouncer = OSAllocatedUnfairLock(initialState: WindowTitleChangeDebouncer<WindowTitleKey>())

func isWindowTitleObservationEnabled() -> Bool {
    windowTitleObservationEnabled.withLock { $0 }
}

/// Optional: the windows that don't support them are still managed. See ``AxWindow/syncTitleChangedSubscription``
var windowTitleChangedHandlers: HandlerToNotifKeyMapping {
    unsafe [(windowTitleChangedObs, [kAXTitleChangedNotification])]
}

private func windowTitleChangedObs(_: AXObserver, ax: AXUIElement, notif _: CFString, _: UnsafeMutableRawPointer?) {
    // The subscriptions are removed asynchronously, a few notifications may still arrive
    guard isWindowTitleObservationEnabled() else { return }
    guard let nativeWindowId = ax.containingNativeWindowId(), let pid = ax.pid else { return }
    let isNewlyPending = titleChangeDebouncer.withLock {
        $0.markChanged(WindowTitleKey(pid: pid, nativeWindowId: nativeWindowId), now: .now)
    }
    // A burst of notifications for the same window costs one MainActor hop
    if isNewlyPending {
        Task.startUnstructured { @MainActor in scheduleWindowTitleChangeProcessing() }
    }
}

// MARK: - Demand

/// Lets the other features react to title changes (e.g. a tab bar that shows the titles).
/// A registered listener turns the AX observation on, like a callback in the config does
@MainActor private var windowTitleChangedListeners: [String: @MainActor (Window, _ title: String) -> Void] = [:]

@MainActor func setWindowTitleChangedListener(id: String, _ listener: (@MainActor (Window, _ title: String) -> Void)?) {
    windowTitleChangedListeners[id] = listener
    syncWindowTitleObservation(resetState: false)
}

/// The observation costs an AX subscription per window and work on every title change, so it's on only when something needs it
@MainActor var isWindowTitleObservationNeeded: Bool {
    !config.onWindowTitleChanged.isEmpty || hasSubscribers(for: .windowTitleChanged) || !windowTitleChangedListeners.isEmpty
}

@MainActor private var reseedTask: Task<(), Never>? = nil

/// Must be called whenever ``isWindowTitleObservationNeeded`` may change.
/// `resetState` forgets the match states, because the callbacks they belong to changed (config reload)
@MainActor func syncWindowTitleObservation(resetState: Bool) {
    let isNeeded = isWindowTitleObservationNeeded
    let wasEnabled = windowTitleObservationEnabled.withLock { isEnabled in
        defer { isEnabled = isNeeded }
        return isEnabled
    }
    let hasChanged = wasEnabled != isNeeded
    if hasChanged {
        for app in MacApp.allAppsMap.values {
            app.syncWindowTitleChangedSubscriptions()
        }
    }
    if !resetState && !hasChanged { return }
    windowTitleStates = [:]
    titleChangeDebouncer.withLock { $0.removeAll() }
    reseedTask?.cancel()
    reseedTask = nil
    if !isNeeded { return }
    // Otherwise, the first title change of every window would be compared against nothing and trigger the callbacks
    // that already matched it
    reseedTask = Task.startUnstructured { @MainActor in
        do {
            for window in MacWindow.allWindows {
                try await seedWindowTitleState(window)
            }
        } catch is CancellationError {
            return // A newer sync started its own reseed
        } catch {
            die("Illegal error: \(error)")
        }
    }
}

// MARK: - State

struct WindowTitleState: Equatable {
    var lastKnownTitle: String
    /// Indexed like `config.onWindowTitleChanged`
    var matches: [Bool]
}

@MainActor private(set) var windowTitleStates: [OpaqueWindowId: WindowTitleState] = [:]
@MainActor private var windowsRunningTitleCallbacks: Set<OpaqueWindowId> = []

@MainActor func forgetWindowTitleState(_ windowId: OpaqueWindowId) {
    windowTitleStates.removeValue(forKey: windowId)
}

/// Remembers the title and the matches of a just detected window. Its first title change is compared against them
@MainActor func seedWindowTitleState(_ window: Window) async throws {
    guard isWindowTitleObservationEnabled(), window.isSubjectToWindowCallbacks else { return }
    let title = try await window.getTitle(.cancellable)
    let matches = await config.onWindowTitleChanged.evaluateMatches(window)
    windowTitleStates[window.windowId] = WindowTitleState(lastKnownTitle: title, matches: matches)
}

// MARK: - Processing

enum WindowTitleChangeResult: Equatable {
    /// Popups and the windows that aren't in the tree
    case ignored
    /// The callbacks of the window are running. It's the re-entry guard
    case busy
    case titleUnchanged
    case noCallbackTriggered
    case callbacksRan(Int32ExitCode)
}

/// `force` runs every matching callback, no matter whether it matched before (`run-callback on-window-title-changed`).
/// `runCallbacks` wraps the run of the triggered callbacks, e.g. in a session
@MainActor
func handleWindowTitleChange(
    _ window: Window,
    force: Bool,
    _ env: CmdEnv,
    _ io: CmdIo,
    runCallbacks: @MainActor (_ body: @MainActor () async -> Int32ExitCode) async throws -> Int32ExitCode,
) async throws -> WindowTitleChangeResult {
    guard window.isSubjectToWindowCallbacks else { return .ignored }
    let windowId = window.windowId
    // The guard covers the whole processing, because every await below lets a new title change of the same window in
    if windowsRunningTitleCallbacks.contains(windowId) { return .busy }
    windowsRunningTitleCallbacks.insert(windowId)
    defer { windowsRunningTitleCallbacks.remove(windowId) }

    let title = try await window.getTitle(.cancellable)
    let previous = windowTitleStates[windowId]
    let isTitleChanged = previous?.lastKnownTitle != title
    if !isTitleChanged && !force { return .titleUnchanged }
    if isTitleChanged {
        broadcastEvent(.windowTitleChanged(
            windowId: windowId,
            workspace: window.nodeWorkspace?.name,
            appBundleId: window.app.rawAppBundleId,
            appName: window.app.name,
            title: title,
        ))
        for listener in windowTitleChangedListeners.values {
            listener(window, title)
        }
    }

    let callbacks = config.onWindowTitleChanged
    let matches = await callbacks.evaluateMatches(window)
    // The window may be closed by now. Then the state would be never forgotten
    if window.isBound {
        windowTitleStates[windowId] = WindowTitleState(lastKnownTitle: title, matches: matches)
    }
    let previousMatches = previous?.matches.count == callbacks.count ? previous?.matches : nil
    let triggered = force
        ? matches
        : zip(previousMatches ?? Array(repeating: false, count: callbacks.count), matches).map { !$0 && $1 }
    if !triggered.contains(true) { return .noCallbackTriggered }

    let exitCode = try await runCallbacks {
        // At least one callback is triggered, so the initial value is always overwritten
        var lastExitCode = Int32ExitCode(rawValue: EXIT_CODE_ZERO)
        for (callback, isTriggered) in zip(callbacks, triggered) where isTriggered {
            lastExitCode = await callback.run.run(env.withWindowId(windowId), io)
            if !callback.checkFurtherCallbacks { break }
        }
        return lastExitCode
    }
    return .callbacksRan(exitCode)
}

/// `run-callback on-window-title-changed`: runs the matching callbacks, no matter whether they matched before
@MainActor
func forceOnWindowTitleChanged(_ env: CmdEnv, _ io: CmdIo, _ window: Window) async -> Int32ExitCode {
    let result: WindowTitleChangeResult
    do {
        result = try await handleWindowTitleChange(window, force: true, env, io) { body in await body() }
    } catch {
        return .fail(io.err("Can't read the title of window \(window.windowId): \(error)"))
    }
    return switch result {
        case .callbacksRan(let exitCode): exitCode
        case .busy: .fail(io.err("on-window-title-changed callbacks of window \(window.windowId) are already running"))
        case .ignored: .fail(io.err("on-window-title-changed callbacks don't run for window \(window.windowId), it's a popup"))
        // Not `.succ`: Int32ExitCode.succ is 2
        case .titleUnchanged, .noCallbackTriggered: Int32ExitCode(rawValue: EXIT_CODE_ZERO)
    }
}

extension [WindowDetectedCallback] {
    @MainActor
    fileprivate func evaluateMatches(_ window: Window) async -> [Bool] {
        var result: [Bool] = []
        for callback in self {
            result.append(await callback.matches(window))
        }
        return result
    }
}

extension Window {
    /// The same windows on-window-detected callbacks run for
    @MainActor
    fileprivate var isSubjectToWindowCallbacks: Bool {
        switch windowParentCases {
            case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: true
            case .macosPopupWindowsContainer, nil: false
        }
    }
}

// MARK: - Debounce loop

/// Only the loop with the latest generation keeps going. Cancellation alone isn't enough: a loop whose sleep has
/// already finished could still resume
@MainActor private var titleChangeLoopGeneration = 0
/// nil while the loop processes the windows. It re-checks the deadlines afterward anyway
@MainActor private var titleChangeLoopWakeUpAt: ContinuousClock.Instant? = nil
@MainActor private var titleChangeLoop: Task<(), Never>? = nil

@MainActor
private func scheduleWindowTitleChangeProcessing() {
    guard let deadline = titleChangeDebouncer.withLock({ $0.nextDeadline }) else { return }
    if titleChangeLoop != nil {
        guard let wakeUpAt = titleChangeLoopWakeUpAt, deadline < wakeUpAt else { return }
        titleChangeLoop?.cancel()
    }
    titleChangeLoopGeneration += 1
    let generation = titleChangeLoopGeneration
    titleChangeLoop = Task.startUnstructured { @MainActor in
        await runWindowTitleChangeLoop(generation)
    }
}

@MainActor
private func runWindowTitleChangeLoop(_ generation: Int) async {
    while let deadline = titleChangeDebouncer.withLock({ $0.nextDeadline }) {
        titleChangeLoopWakeUpAt = deadline
        do {
            try await Task.sleep(until: deadline, clock: .continuous)
        } catch is CancellationError {
            return // Superseded by a loop that wakes up earlier
        } catch {
            die("Illegal error: \(error)")
        }
        guard generation == titleChangeLoopGeneration else { return }
        titleChangeLoopWakeUpAt = nil
        for key in titleChangeDebouncer.withLock({ $0.takeDue(now: .now) }) {
            await processWindowTitleChange(key)
        }
    }
    titleChangeLoop = nil
    titleChangeLoopWakeUpAt = nil
}

@MainActor
private func processWindowTitleChange(_ key: WindowTitleKey) async {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    guard let window = Window.get(byNativeId: key.nativeWindowId, pid: key.pid) else {
        titleChangeDebouncer.withLock { $0.forget(key) }
        return
    }
    // The callbacks would move the window from under the mouse. Try again once the grab is over
    if isGrabbedWithMouse(nativeWindowId: key.nativeWindowId) {
        titleChangeDebouncer.withLock { _ = $0.markChanged(key, now: .now) }
        return
    }
    let result: WindowTitleChangeResult
    do {
        result = try await handleWindowTitleChange(window, force: false, .defaultEnv, CmdIoImpl.emptyStdinIgnoringOut) { body in
            try await runLightSession(.windowTitleChanged, token) { await body() }
        }
    } catch is CancellationError {
        return // Only the AX reads are cancellable. The window will be processed on its next title change
    } catch {
        die("Illegal error: \(error)")
    }
    switch result {
        case .busy:
            titleChangeDebouncer.withLock { _ = $0.markChanged(key, now: .now) }
        case .callbacksRan:
            titleChangeDebouncer.withLock { $0.recordRun(key, now: .now) }
        case .ignored, .titleUnchanged, .noCallbackTriggered:
            break
    }
}
