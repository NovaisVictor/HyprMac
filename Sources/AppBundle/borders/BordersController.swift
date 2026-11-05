import AppKit
import Common

enum BorderRole: Equatable {
    case active, inactive
}

/// A border window, as the controller sees it. Tests replace it, because real windows need a WindowServer
@MainActor
protocol BorderOverlay: AnyObject {
    var windowNumber: Int { get }
    /// `frame` is in AppKit coordinates
    func place(_ frame: CGRect, ring: BorderRing, level: Int)
    func setRole(_ role: BorderRole, animated: Bool)
    /// The border appears right next to `target` in the z-order: above it or below it.
    /// A nil target makes it appear in front of every window
    func show(nextTo target: (nativeWindowId: UInt32, above: Bool)?)
    /// Orders a shown border right next to `target` again, e.g. after its app raised the window
    func reorder(nextTo target: (nativeWindowId: UInt32, above: Bool))
    func hide()
    func dispose()
}

/// The windows that get a border right now, and the border they get. A window absent from the result has its border
/// hidden:
/// - windows of invisible workspaces: HyprMac hides them in a corner of the monitor;
/// - macOS fullscreen and minimized windows, the windows of hidden apps, and popups. Dialogs are floating windows,
///   so they do get a border;
/// - tiling windows covered by a HyprMac fullscreen window;
/// - inactive windows when `inactive-color = ''`.
/// HyprMac's own windows are never managed (MacApp skips its own pid), so they never get a border
@MainActor
func borderRoles(focus: Window?, showsInactive: Bool, isAeroSpaceEnabled: Bool) -> [OpaqueWindowId: BorderRole] {
    if !isAeroSpaceEnabled { return [:] }
    var result: [OpaqueWindowId: BorderRole] = [:]
    for workspace in Workspace.all where workspace.isVisible {
        let fullscreenWindow = workspace.rootTilingContainer.mostRecentWindowRecursive?.takeIf(\.isFullscreen)
        for window in workspace.allLeafWindowsRecursive where window.lifeStatus == .alive {
            switch window.windowParentCases {
                case .tilingContainer:
                    if let fullscreenWindow, fullscreenWindow != window { continue }
                case .floatingWindowsContainer: break
                case .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosMinimizedWindowsContainer,
                     .macosPopupWindowsContainer, nil:
                    continue
            }
            if window == focus {
                result[window.windowId] = .active
            } else if showsInactive {
                result[window.windowId] = .inactive
            }
        }
    }
    return result
}

/// The radius when macOS can't tell the real one: the radius that JankyBorders falls back to
let unknownWindowRadius: CGFloat = 9

/// Keeps one border window per window that needs one. A border window is created the first time its window needs a
/// border, hidden while the window doesn't need one, and closed when the window is gone
@MainActor
final class BordersController {
    let config: BordersConfig
    private let windowServer: any BorderWindowServer
    private let makeOverlay: @MainActor (BordersConfig) -> any BorderOverlay
    private let mainMonitorHeight: @MainActor () -> CGFloat
    private let glowMargin: CGFloat
    private var entries: [OpaqueWindowId: Entry] = [:]
    private var windowIdByNativeId: [UInt32: OpaqueWindowId] = [:]
    private var watchedNativeIds: [UInt32] = []
    /// Schedules ``verifyOrder()`` after a reconcile. Injectable, so that tests can run the verification by hand
    private let scheduleOrderVerification: @MainActor (_ verify: @escaping @MainActor () -> Void) -> Void

    private struct Entry {
        let overlay: any BorderOverlay
        var nativeWindowId: UInt32
        var role: BorderRole?
        /// The last frame of the window, in top-left coordinates. Lets a move without a size keep the size
        var targetFrame: Rect?
        /// Read when the border is created and when its window is resized, never on a move: the WindowServer is asked
        /// for it, and a move doesn't change the corners of a window
        var windowRadius: CGFloat
        var level: Int = NSWindow.Level.normal.rawValue
    }

    init(
        _ config: BordersConfig,
        windowServer: any BorderWindowServer,
        mainMonitorHeight: @escaping @MainActor () -> CGFloat = { mainMonitorInfo.height },
        makeOverlay: @escaping @MainActor (BordersConfig) -> any BorderOverlay = { BorderPanel($0) },
        scheduleOrderVerification: @escaping @MainActor (_ verify: @escaping @MainActor () -> Void) -> Void = scheduleBorderOrderVerification,
    ) {
        self.config = config
        self.windowServer = windowServer
        self.mainMonitorHeight = mainMonitorHeight
        self.makeOverlay = makeOverlay
        self.scheduleOrderVerification = scheduleOrderVerification
        glowMargin = borderGlowMargin(config)
    }

    var notifiesWindowMoves: Bool { windowServer.notifiesWindowMoves }

    /// `nativeWindowIds` maps the windows that exist to their WindowServer ids. The borders of the other windows close
    func reconcile(_ roles: [OpaqueWindowId: BorderRole], nativeWindowIds: [OpaqueWindowId: UInt32]) {
        for (windowId, entry) in entries where nativeWindowIds[windowId] == nil {
            entry.overlay.dispose()
            entries.removeValue(forKey: windowId)
        }
        for (windowId, var entry) in entries where roles[windowId] == nil {
            if entry.role != nil {
                entry.overlay.hide()
                entry.role = nil
                entries[windowId] = entry
            }
        }
        var isAnyOrdered = false
        for (windowId, role) in roles {
            guard let nativeWindowId = nativeWindowIds[windowId] else { continue }
            var entry = entries[windowId]
                ?? Entry(overlay: makeOverlay(config), nativeWindowId: nativeWindowId, windowRadius: windowRadius(nativeWindowId))
            if entry.nativeWindowId != nativeWindowId {
                entry.nativeWindowId = nativeWindowId
                entry.windowRadius = windowRadius(nativeWindowId)
            }
            guard let info = windowServer.targetInfo(nativeWindowId) else {
                // The window is gone from the WindowServer before HyprMac noticed it
                if entry.role != nil { entry.overlay.hide() }
                entry.role = nil
                entries[windowId] = entry
                continue
            }
            // A border that appears gets its color right away. Only a focus change is a transition
            if entry.role != role { entry.overlay.setRole(role, animated: entry.role != nil) }
            entry.role = role
            if let previous = entry.targetFrame, previous.size != info.frame.size { entry.windowRadius = windowRadius(nativeWindowId) }
            entry.targetFrame = info.frame
            entry.level = info.level
            entry.overlay.place(borderCocoaFrame(info.frame), ring: ring(entry), level: borderLevel(info.level))
            // Appearing right next to the window, rather than in front and reordered right after: the reorder raced
            // with the AppKit ordering and could leave the border above a window that it must stay below
            let target = orderTarget(nativeWindowId)
            entry.overlay.show(nextTo: target)
            // Already shown borders don't move in the z-order by themselves, while their windows get raised
            if let target {
                entry.overlay.reorder(nextTo: target)
                isAnyOrdered = true
            }
            entries[windowId] = entry
        }
        windowIdByNativeId = Dictionary(entries.map { ($0.value.nativeWindowId, $0.key) }, uniquingKeysWith: { _, new in new })
        if isAnyOrdered { scheduleOrderVerification { [weak self] in self?.verifyOrder() } }
        // A hidden border doesn't follow its window. The next reconcile places it when it's shown again
        let nativeIds = entries.values.filter { $0.role != nil }.map(\.nativeWindowId).sorted()
        if nativeIds != watchedNativeIds {
            watchedNativeIds = nativeIds
            windowServer.watch(nativeIds)
        }
    }

    /// The WindowServer reports a change of a window. Only with ``BorderWindowServer/notifiesWindowMoves``
    func onWindowServerEvent(_ event: SkyLightWindowEvent, _ nativeWindowId: UInt32) {
        guard let windowId = windowIdByNativeId[nativeWindowId], var entry = entries[windowId], entry.role != nil else { return }
        switch event {
            case .moved, .resized:
                guard let info = windowServer.targetInfo(nativeWindowId) else { return }
                place(&entry, frame: info.frame, level: info.level)
                entries[windowId] = entry
            case .reordered:
                // The window was raised or lowered, e.g. by its app right after AeroSpace focused it, and may now cover
                // a border that must stay above it. Ordering the border reorders the window too, so the border is
                // ordered only when it isn't next to its window already: otherwise the two would chase each other
                guard let border = UInt32(exactly: entry.overlay.windowNumber), let target = orderTarget(nativeWindowId),
                      !windowServer.isOrderedNextTo(border: border, target: nativeWindowId)
                else { return }
                entry.overlay.reorder(nextTo: target)
        }
    }

    /// HyprMac is about to write the frame of the window. Without WindowServer notifications, that's the earliest
    /// moment the border can follow. `topLeft` or `size` is nil when it doesn't change
    func onFrameWrite(_ windowId: OpaqueWindowId, topLeft: CGPoint?, size: CGSize?) {
        guard var entry = entries[windowId], entry.role != nil, let current = entry.targetFrame else { return }
        let frame = Rect(
            topLeftX: topLeft?.x ?? current.topLeftX,
            topLeftY: topLeft?.y ?? current.topLeftY,
            width: size?.width ?? current.width,
            height: size?.height ?? current.height,
        )
        place(&entry, frame: frame, level: entry.level)
        entries[windowId] = entry
    }

    /// An AX notification says that the app moved or resized the window by itself, or that the user dragged it
    func onAxFrameChange(_ nativeWindowId: UInt32) {
        guard let windowId = windowIdByNativeId[nativeWindowId], var entry = entries[windowId], entry.role != nil,
              let info = windowServer.targetInfo(nativeWindowId)
        else { return }
        place(&entry, frame: info.frame, level: info.level)
        entries[windowId] = entry
    }

    /// An app often raises its window right after AeroSpace focused it, and the window then covers a border that must
    /// stay above it. The WindowServer doesn't always report that reorder, so the order is checked again a bit later
    func verifyOrder() {
        for entry in entries.values where entry.role != nil {
            guard let border = UInt32(exactly: entry.overlay.windowNumber), let target = orderTarget(entry.nativeWindowId),
                  !windowServer.isOrderedNextTo(border: border, target: entry.nativeWindowId)
            else { continue }
            entry.overlay.reorder(nextTo: target)
        }
    }

    func disposeAll() {
        for entry in entries.values {
            entry.overlay.dispose()
        }
        entries = [:]
        windowIdByNativeId = [:]
        if !watchedNativeIds.isEmpty { windowServer.watch([]) }
        watchedNativeIds = []
    }

    private func place(_ entry: inout Entry, frame: Rect, level: Int) {
        if entry.targetFrame == frame && entry.level == level { return }
        if entry.targetFrame?.size != frame.size { entry.windowRadius = windowRadius(entry.nativeWindowId) }
        entry.targetFrame = frame
        entry.level = level
        entry.overlay.place(borderCocoaFrame(frame), ring: ring(entry), level: borderLevel(level))
    }

    /// Where the border goes in the z-order relative to its window. nil when the borders float above all the windows.
    /// The borders are always ordered by AppKit: SkyLight can lower an AppKit window relative to the window of another
    /// app, but silently fails to raise it, which left the borders under the windows that their apps had just raised
    private func orderTarget(_ nativeWindowId: UInt32) -> (nativeWindowId: UInt32, above: Bool)? {
        switch windowServer.placement {
            case .belowWindow: (nativeWindowId, false)
            case .rightAboveWindow: (nativeWindowId, true)
            case .aboveWindow: nil
        }
    }

    private func windowRadius(_ nativeWindowId: UInt32) -> CGFloat {
        switch config.radius {
            case .auto: windowServer.cornerRadius(nativeWindowId) ?? unknownWindowRadius
            case .fixed(let radius): CGFloat(radius)
        }
    }

    private func ring(_ entry: Entry) -> BorderRing {
        borderRing(windowRadius: entry.windowRadius, width: CGFloat(config.width), placement: windowServer.placement)
    }

    private func borderLevel(_ windowLevel: Int) -> Int {
        switch windowServer.placement {
            case .belowWindow, .rightAboveWindow: windowLevel
            case .aboveWindow: NSWindow.Level.floating.rawValue
        }
    }

    private func borderCocoaFrame(_ windowFrame: Rect) -> CGRect {
        cocoaFrame(borderFrame(around: windowFrame, width: CGFloat(config.width), glowMargin: glowMargin), mainMonitorHeight: mainMonitorHeight())
    }
}

/// The app raises its window within a few frames after the focus, sometimes later when it's busy:
/// one early check fixes most of the cases quickly, and a later one catches the slow apps.
/// A new reconcile cancels the pending checks: it orders the borders again and schedules its own checks
@MainActor private var borderOrderVerificationTask: Task<(), any Error>? = nil

@MainActor
func scheduleBorderOrderVerification(_ verify: @escaping @MainActor () -> Void) {
    borderOrderVerificationTask?.cancel()
    borderOrderVerificationTask = Task.startUnstructured { @MainActor in
        for delay in [Duration.milliseconds(150), .milliseconds(400)] {
            try await Task.sleep(for: delay)
            verify()
        }
    }
}
