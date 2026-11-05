import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?
    /// Size requested by floating-frame while the window was hidden in a corner. Applied by unhideFromCorner
    private var floatingSizeToApplyOnUnhide: CGSize?

    @MainActor private init(
        _ id: OpaqueWindowId,
        _ actor: MacApp,
        lastFloatingSize: CGSize?,
        parent: NonLeafTreeNodeObject,
        adaptiveWeight: CGFloat,
        index: Int,
    ) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [OpaqueWindowId: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: OpaqueWindowId, macApp: MacApp) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        let rect = try await macApp.getAxRect(windowId, .cancellable)
        let workspace = isStartup
            ? (rect?.center.monitorApproximation ?? mainMonitorInfo).visibleWorkspace
            : globalFocus.workspace
        let parentKind = try await getNewWindowParentKind(windowId, macApp, .cancellable)
        let initialPlacement = parentKind.initialPlacement(workspace)
        // The prediction below runs in the synchronous section, so the title must be read in advance
        let title = initialPlacement != nil && config.onWindowDetected.contains(where: \.matcher.needsWindowTitle)
            ? try await macApp.getAxTitle(windowId, .cancellable) ?? ""
            : nil

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] { return existing }
        let prediction = initialPlacement.flatMap {
            predictOnWindowDetected(windowId: windowId, initialPlacement: $0, app: macApp, title: title)
        }
        let data = prediction?.placement.unbindAndGetBindingData() ?? parentKind.unbindAndGetBindingData(workspace, window: nil)
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        allWindowsMap[windowId] = window

        try await debugWindowsIfRecording(window, .cancellable)
        if try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            await runOnWindowDetected(ifConventional: window, prediction)
        }
        try await seedWindowTitleState(window)
        return window
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel, cm)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel, cm)
    }

    func dumpAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId, cm)
    }

    @MainActor func getWindowLevel(_ cm: CancellationMode) async throws -> MacOsWindowLevel? {
        try await macApp.getWindowLevel(windowId, cm)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        forgetScratchpadState(windowId: windowId)
        forgetWindowTitleState(windowId)
        pinnedWindowIds.remove(windowId)
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        // Popups are never reported by window-detected, so their destruction isn't reported either
        if parent !== macosPopupWindowsContainer {
            broadcastEvent(.windowClosed(
                windowId: windowId,
                workspace: deadWindowWorkspace?.name,
                appBundleId: app.rawAppBundleId,
                appName: app.name,
            ))
        }
        let focus = globalFocus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .monitor, // Monitor is invalid parent for windows
                     .workspacesContainer, // WorkspacesContainer is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { try await macApp.getAxTitle(windowId, cm) ?? "" }

    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeFullscreen(windowId, cm) == true }
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeMinimized(windowId, cm) == true }
    override func getMacosWindowNativeState(_ cm: CancellationMode) async throws -> MacosWindowNativeState {
        try await macApp.getMacosWindowNativeState(windowId, cm) ?? .normal
    }

    @MainActor override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        // The slot is stale by the time the workspace is shown again: the window must jump into its new slot
        // instead of sliding in from the old one
        lastAppliedLayoutPhysicalRect = nil
        guard let nodeMonitorInfo else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            guard let windowRect = try await getAxRect(.cancellable) else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                prevUnhiddenProportionalPositionInsideWorkspaceRect =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
                if isFloating {
                    lastFloatingSize = windowRect.size
                }
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize(.cancellable) else { fallthrough }
                // Zoom will jump off if you do one pixel offset
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitorInfo.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitorInfo.visibleRect.bottomRightCorner - onePixelOffset
        }
        setAxFrame(p, nil)
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                let workspaceRect = nodeWorkspace.workspaceMonitorInfo.rect
                var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
                var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                let windowWidth = lastFloatingSize?.width ?? 0
                let windowHeight = lastFloatingSize?.height ?? 0
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                setAxFrame(CGPoint(x: newX, y: newY), floatingSizeToApplyOnUnhide)
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
        self.floatingSizeToApplyOnUnhide = nil
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    @MainActor
    override func getUnhiddenFloatingRect(_ cm: CancellationMode) async throws -> Rect? {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect, let nodeWorkspace else { return try await getAxRect(cm) }
        // While hidden in the corner, the AX position is meaningless. Reconstruct what unhideFromCorner would restore
        let topLeft = nodeWorkspace.workspaceMonitorInfo.rect.absolutePoint(fromProportional: prevUnhiddenProportionalPositionInsideWorkspaceRect)
        let size: CGSize
        if let lastFloatingSize {
            size = lastFloatingSize
        } else if let axSize = try await getAxSize(cm) {
            size = axSize
        } else {
            return nil
        }
        return Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height)
    }

    @MainActor
    override func setFloatingFrame(_ rect: Rect) {
        guard isHiddenInCorner, let nodeWorkspace else {
            super.setFloatingFrame(rect)
            return
        }
        // Applying the frame now would reveal the hidden window. Instead, store it in the same form hideInCorner does,
        // so that unhideFromCorner restores the new frame rather than the one the window had before it was hidden
        lastFloatingSize = rect.size
        floatingSizeToApplyOnUnhide = rect.size
        prevUnhiddenProportionalPositionInsideWorkspaceRect =
            nodeWorkspace.workspaceMonitorInfo.rect.proportionalPoint(rect.topLeftCorner)
    }

    @MainActor override func rememberFrameToUnhide(_ rect: Rect, monitorRect: Rect) {
        // The same form hideInCorner stores, relative to the monitor the window is on before it's hidden
        prevUnhiddenProportionalPositionInsideWorkspaceRect = monitorRect.proportionalPoint(rect.topLeftCorner)
        lastFloatingSize = rect.size
    }

    @MainActor override func forgetHiddenInCornerPosition() {
        prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
        // A frame stored by floating-frame for the hidden window would otherwise override the explicit placement
        floatingSizeToApplyOnUnhide = nil
    }

    override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        try await macApp.getAxSize(windowId, cm)
    }

    override func setNativeAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        macApp.setAxFrame(windowId, topLeft, size)
    }

    @MainActor override func expectAnimationEcho() {
        guard let nativeWindowId = macApp.nativeWindowId(of: windowId) else { return }
        markAnimationEcho(AnimationEchoKey(pid: macApp.pid, nativeWindowId: nativeWindowId))
    }

    override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        try await macApp.getAxRect(windowId, cm)
    }
}

@MainActor
func runOnWindowDetected(ifConventional window: Window, _ prediction: OnWindowDetectedPrediction? = nil) async {
    switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            let layout = global_layoutForNextDetectedWindow
            global_layoutForNextDetectedWindow = nil
            defer {
                if let layout {
                    await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [layout]))
                        .run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
                }
            }
            if let layout {
                await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [layout]))
                    .run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
            }
            _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window, prediction)
        case .macosPopupWindowsContainer, nil:
            break
    }
}

@MainActor
func onWindowDetected(_ env: CmdEnv, _ io: CmdIo, _ window: Window, _ prediction: OnWindowDetectedPrediction? = nil) async -> Int32ExitCode {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
    ))
    rememberDetectedWindowWorkspace(window)
    var lastExitCode = Int32ExitCode.succ
    for (index, callback) in (prediction?.callbacks ?? config.onWindowDetected).enumerated() {
        let isMatch = if let predicted = prediction?.matches.getOrNil(atIndex: index) { predicted } else { await callback.matches(window) }
        if !isMatch { continue }
        lastExitCode = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks {
            return lastExitCode
        }
    }
    return lastExitCode
}

extension WindowDetectedCallback {
    @MainActor
    func matches(_ window: Window) async -> Bool {
        switch self.matcher {
            case .legacy(let matcher):
                let title = matcher.windowTitleRegexSubstring != nil ? try? await window.getTitle(.nonCancellable) : nil
                return matcher.matches(window.app, workspace: window.nodeWorkspace?.name, title: title)
            case .command(let command):
                return await command.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin).exitCode.rawValue == 0
        }
    }
}

extension LegacyWindowDetectedCallbackMatcher {
    /// `title` is only checked if the matcher has `window-title-regex-substring`
    @MainActor
    func matches(_ app: any AbstractApp, workspace: String?, title: String?) -> Bool {
        if let duringHyprMacStartup, duringHyprMacStartup != isStartup {
            return false
        }
        if let regex = windowTitleRegexSubstring, title?.contains(caseInsensitiveRegex: regex) != true {
            return false
        }
        if let appId, appId != app.rawAppBundleId {
            return false
        }
        if let regex = appNameRegexSubstring, !(app.name ?? "").contains(caseInsensitiveRegex: regex) {
            return false
        }
        if let expected = self.workspace, expected != workspace {
            return false
        }
        return true
    }
}
