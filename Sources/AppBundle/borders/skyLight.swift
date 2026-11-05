import AppKit
import Common

// This file is the only place in HyprMac that talks to SkyLight, the private framework of the WindowServer.
// ROADMAP.md, decision 9: private SkyLight APIs are allowed in the borders module only, and nowhere else.
//
// - SkyLight is loaded at runtime with dlopen/dlsym and never linked. A macOS update that removes or renames any of
//   ``skyLightRequiredSymbols`` makes ``loadSkyLight(_:)`` fail, and the borders fall back to public APIs instead of
//   crashing. ``skyLightCornerRadiusSymbols`` are optional: without them, only the corner radius of the windows is
//   unknown, and the borders keep the SkyLight path.
// - The signatures are the facts that every SkyLight client relies on (JankyBorders, yabai). The code is our own.
//   JankyBorders is GPL-3.0: we studied which calls it makes and in which order, but none of its code is here.
// - Verified on the development machine by BordersTest: every symbol of ``skyLightRequiredSymbols`` resolves.
//   Only believed, never exercised by a test: the behavior of the calls, listed next to each of them.

let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

/// `dlsym` by name. Injectable, so that tests can simulate a macOS without one of the symbols
typealias SkyLightSymbolResolver = (_ symbol: String) -> UnsafeMutableRawPointer?

let skyLightRequiredSymbols: [String] = [
    "SLSMainConnectionID",
    "SLSGetWindowBounds",
    "SLSGetWindowLevel",
    "SLSRegisterNotifyProc",
    "SLSRequestNotificationsForWindows",
]

/// The query of the corner radius of a window. macOS 26 is the first version that rounds the corners of each window
/// differently, and the first one where JankyBorders reads them
let skyLightCornerRadiusSymbols: [String] = [
    "SLSWindowQueryWindows",
    "SLSWindowQueryResultCopyWindows",
    "SLSWindowIteratorAdvance",
    "SLSWindowIteratorGetCornerRadii",
]

/// nil when the framework can't be opened. The handle is never closed: SkyLight is part of every GUI process anyway
func openSkyLightResolver() -> SkyLightSymbolResolver? {
    guard let handle = unsafe dlopen(skyLightPath, RTLD_LAZY | RTLD_LOCAL) else { return nil }
    return { symbol in unsafe dlsym(handle, symbol) }
}

/// WindowServer notification ids. They are not documented anywhere, they are the values that SkyLight clients use
enum SkyLightWindowEvent: UInt32, CaseIterable {
    case moved = 806
    case resized = 807
    /// The window changed its place in the z-order, e.g. it was brought to the front
    case reordered = 808
}

private typealias MainConnectionIdFn = @convention(c) () -> Int32
private typealias GetWindowBoundsFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError
private typealias GetWindowLevelFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int64>) -> CGError
private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
private typealias RegisterNotifyProcFn = @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> CGError
private typealias RequestNotificationsForWindowsFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>?, Int32) -> CGError
private typealias WindowQueryWindowsFn = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
private typealias WindowQueryResultCopyWindowsFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
private typealias WindowIteratorAdvanceFn = @convention(c) (CFTypeRef) -> Bool
private typealias WindowIteratorGetCornerRadiiFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

private struct CornerRadiusFns {
    let queryWindows: WindowQueryWindowsFn
    let queryResultCopyWindows: WindowQueryResultCopyWindowsFn
    let iteratorAdvance: WindowIteratorAdvanceFn
    let iteratorGetCornerRadii: WindowIteratorGetCornerRadiiFn
}


// @safe: the pointers of the C signatures never leave this class, its methods only take and return values
@MainActor
@safe final class SkyLight {
    private let connectionId: Int32
    private let getWindowBoundsFn: GetWindowBoundsFn
    private let getWindowLevelFn: GetWindowLevelFn
    private let registerNotifyProcFn: RegisterNotifyProcFn
    private let requestNotificationsForWindowsFn: RequestNotificationsForWindowsFn
    private let cornerRadiusFns: CornerRadiusFns?

    /// `symbols` has every required symbol, and the optional ones that resolve
    fileprivate init(_ symbols: [String: UnsafeMutableRawPointer]) {
        func fn<T>(_ name: String, _: T.Type) -> T { unsafe unsafeBitCast(symbols[name].orDie(), to: T.self) }
        // The connection of the process. Our own windows (the borders) belong to it, so it may reorder them
        connectionId = fn("SLSMainConnectionID", MainConnectionIdFn.self)()
        unsafe getWindowBoundsFn = unsafe fn("SLSGetWindowBounds", GetWindowBoundsFn.self)
        unsafe getWindowLevelFn = unsafe fn("SLSGetWindowLevel", GetWindowLevelFn.self)
        unsafe registerNotifyProcFn = unsafe fn("SLSRegisterNotifyProc", RegisterNotifyProcFn.self)
        unsafe requestNotificationsForWindowsFn = unsafe fn("SLSRequestNotificationsForWindows", RequestNotificationsForWindowsFn.self)
        cornerRadiusFns = skyLightCornerRadiusSymbols.allSatisfy { unsafe symbols[$0] != nil }
            ? unsafe CornerRadiusFns(
                queryWindows: fn("SLSWindowQueryWindows", WindowQueryWindowsFn.self),
                queryResultCopyWindows: fn("SLSWindowQueryResultCopyWindows", WindowQueryResultCopyWindowsFn.self),
                iteratorAdvance: fn("SLSWindowIteratorAdvance", WindowIteratorAdvanceFn.self),
                iteratorGetCornerRadii: fn("SLSWindowIteratorGetCornerRadii", WindowIteratorGetCornerRadiiFn.self),
            )
            : nil
    }

    /// Whether ``cornerRadius(of:)`` can tell anything
    var detectsCornerRadius: Bool { cornerRadiusFns != nil }

    /// The radius of the first corner of any window of any app, the corner that JankyBorders reads too. Seen on
    /// macOS 26: an array of the four corners, all equal, e.g. 16 for a Chromium window and 0 for a window that draws
    /// its own frame. nil when SkyLight can't tell. Like JankyBorders, a radius of 0 counts as unknown
    func cornerRadius(of windowId: UInt32) -> CGFloat? {
        guard let fns = cornerRadiusFns else { return nil }
        // 32 bit numbers, like JankyBorders builds them
        var rawId = Int32(bitPattern: windowId)
        guard let number = unsafe CFNumberCreate(nil, .sInt32Type, &rawId) else { return nil }
        let windowIds = [number] as CFArray
        // JankyBorders releases the query, so it's owned despite its name: takeRetainedValue
        guard let query = unsafe fns.queryWindows(connectionId, windowIds, 0)?.takeRetainedValue() else { return nil }
        // Kept alive until the iterator is done: nothing says that the iterator retains the result it walks
        return withExtendedLifetime(query) {
            // A Copy function: owned, takeRetainedValue
            guard let iterator = unsafe fns.queryResultCopyWindows(query)?.takeRetainedValue(),
                  fns.iteratorAdvance(iterator),
                  // A Get function by its name, but JankyBorders releases the array, and on macOS 26 its retain
                  // count is 2 when the iterator is still alive: one of them is ours, takeRetainedValue
                  let radii = unsafe fns.iteratorGetCornerRadii(iterator)?.takeRetainedValue(),
                  let radius = (radii as NSArray).firstObject as? NSNumber
            else { return nil }
            return radius.doubleValue > 0 ? CGFloat(radius.doubleValue) : nil
        }
    }

    /// Believed: the frame in the global top-left coordinates, the same ones as the AX API, of any window of any app
    func windowBounds(_ windowId: UInt32) -> CGRect? {
        var rect = CGRect.zero
        return unsafe getWindowBoundsFn(connectionId, windowId, &rect) == .success ? rect : nil
    }

    /// Believed: the same value as `kCGWindowLayer`, and as the raw value of `NSWindow.Level`
    func windowLevel(_ windowId: UInt32) -> Int? {
        var level: Int64 = 0
        return unsafe getWindowLevelFn(connectionId, windowId, &level) == .success ? Int(level) : nil
    }

    /// Believed: replaces the set of windows whose ``SkyLightWindowEvent``s this process receives
    func requestNotifications(for windowIds: [UInt32]) -> Bool {
        var windowIds = windowIds
        return windowIds.withUnsafeMutableBufferPointer { buffer in
            unsafe requestNotificationsForWindowsFn(connectionId, buffer.baseAddress, Int32(buffer.count)) == .success
        }
    }

    /// The handler of the events that ``requestNotifications(for:)`` subscribes to.
    /// SkyLight has no way to unregister a notification proc, so it's registered once per process,
    /// and the handler is swapped instead
    static var windowEventHandler: (@MainActor (SkyLightWindowEvent, UInt32) -> Void)? = nil
    private static var isNotifyProcRegistered = false

    func registerWindowEventsOnce() -> Bool {
        if Self.isNotifyProcRegistered { return true }
        var isOk = true
        for event in SkyLightWindowEvent.allCases {
            isOk = unsafe registerNotifyProcFn(skyLightNotifyProc, event.rawValue, nil) == .success && isOk
        }
        Self.isNotifyProcRegistered = isOk
        return isOk
    }
}

/// Believed: SkyLight calls the procs on the thread that receives the events of the main connection, which in an
/// AppKit app is the main thread. The hop covers the other case anyway
private let skyLightNotifyProc: NotifyProc = { rawEvent, data, length, _ in
    guard let event = SkyLightWindowEvent(rawValue: rawEvent), let data = unsafe data, length >= MemoryLayout<UInt32>.size else { return }
    let windowId = unsafe data.loadUnaligned(as: UInt32.self)
    if Thread.isMainThread {
        MainActor.assumeIsolated { SkyLight.windowEventHandler?(event, windowId) }
    } else {
        Task.startUnstructured { @MainActor in SkyLight.windowEventHandler?(event, windowId) }
    }
}

enum SkyLightLoadResult {
    case loaded(SkyLight)
    case frameworkUnavailable
    case missingSymbols([String])
}

/// Every symbol is resolved before any of them is called: either the whole SkyLight path works, or none of it is used.
/// The optional symbols only enable ``SkyLight/cornerRadius(of:)``
@MainActor
func loadSkyLight(_ resolver: SkyLightSymbolResolver?) -> SkyLightLoadResult {
    guard let resolver = unsafe resolver else { return .frameworkUnavailable }
    var symbols: [String: UnsafeMutableRawPointer] = unsafe [:]
    var missing: [String] = []
    for name in skyLightRequiredSymbols {
        if let symbol = unsafe resolver(name) {
            unsafe symbols[name] = symbol
        } else {
            missing.append(name)
        }
    }
    // Like JankyBorders: before macOS 26, a symbol of the same name may exist with a behavior nobody has checked
    if #available(macOS 26, *) {
        for name in skyLightCornerRadiusSymbols {
            if let symbol = unsafe resolver(name) { unsafe symbols[name] = symbol }
        }
    }
    return missing.isEmpty ? .loaded(unsafe SkyLight(symbols)) : .missingSymbols(missing)
}
