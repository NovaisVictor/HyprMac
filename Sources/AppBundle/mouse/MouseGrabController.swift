import AppKit
import Common

// MainActor side of the mouse grab: receives the events of the tap thread and moves/resizes the grabbed window.
// By default, the tree isn't mutated during the gesture, so cancelling only needs a layout to put everything back.
// With `mouse-grab.live-preview`, see MouseGrabPreview

private struct MouseGrab {
    let window: Window
    let kind: GrabKind
    let button: MouseButton
    let corner: ResizeCorner
    let startMouse: CGPoint
    let startRect: Rect
    let monitors: [CGRect]
    var mouse: CGPoint
    var rect: Rect
}

@MainActor private var activeGrab: MouseGrab? = nil
/// Only for tiling windows, and only with `mouse-grab.live-preview`
@MainActor private var activePreview: MouseGrabPreview? = nil
@MainActor private var grabWatchdogTask: Task<(), any Error>? = nil
@MainActor private var grabEndTask: Task<(), any Error>? = nil

@MainActor var isMouseGrabActive: Bool { activeGrab != nil }

@MainActor func drainMouseGrabTapEvents() {
    for event in takePendingMouseGrabTapEvents() {
        switch event {
            case .begin(let kind, let button, let point): beginMouseGrab(kind, button, point)
            case .drag(let point): updateMouseGrab(point)
            case .end(let point): endMouseGrab(point)
            case .cancel: finishMouseGrab(drop: false) // The tap has already released the button
        }
    }
}

/// Ends the grab without dropping: tiling windows return to their place
@MainActor func cancelMouseGrab() {
    guard let grab = activeGrab else { return }
    if !isPhysicallyPressed(grab.button) {
        resetMouseGrabTapState(ifGrabbing: grab.button)
    }
    finishMouseGrab(drop: false)
}

@MainActor private func beginMouseGrab(_ kind: GrabKind, _ button: MouseButton, _ point: CGPoint) {
    finishMouseGrab(drop: false) // The tap has already decided that the previous grab is over
    // When no window qualifies, the tap still swallows the click, and the grab is a harmless no-op
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    guard let (window, nativeWindowId, bounds) = managedWindowUnder(point) else { return }
    if window.isHiddenInCorner { return }
    let startRect: Rect
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            startRect = bounds
        case .tilingContainer:
            // The layout knows the slot without asking the app. A fullscreen window has no slot and can't be grabbed
            guard let slot = window.lastAppliedLayoutPhysicalRect else { return }
            // A pseudotiled window is smaller than its slot. The grab must start from where the window really is
            startRect = window.pseudoTiledFrame(in: slot)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer, nil:
            return
    }
    resetClosedWindowsCache()
    activeGrab = MouseGrab(
        window: window,
        kind: kind,
        button: button,
        corner: ResizeCorner(nearestTo: point, of: startRect),
        startMouse: point,
        startRect: startRect,
        monitors: monitorsFingerprint(),
        mouse: point,
        rect: startRect,
    )
    // Resizing a pseudotiled window changes only its own size, there is nothing to preview in the tree
    if config.mouseGrab.livePreview, case .tilingContainer = window.windowParentCases, !(kind == .resize && window.isPseudoTiled) {
        activePreview = MouseGrabPreview(window, kind, startRect: startRect, mouse: point, after: grabEndTask)
    }
    // Otherwise, the animation keeps changing the frame that the grab starts from
    frameAnimator.finish(window)
    setGrabbedWithMouseNativeWindowId(nativeWindowId)
    currentlyManipulatedWithMouseWindowId = window.windowId
    startGrabWatchdog()
    Task.startUnstructured { @MainActor in
        // Raise the window above its neighbours and keep the keyboard focus on what is being dragged
        try await runLightSession(.mouseGrab, token) {
            _ = window.focusWindow()
            window.nativeFocus()
        }
    }
}

@MainActor private func updateMouseGrab(_ point: CGPoint, isFinalEvent: Bool = false) {
    guard var grab = activeGrab else { return }
    if !isStillValid(grab, isFinalEvent: isFinalEvent) {
        cancelMouseGrab()
        return
    }
    grab.mouse = point
    switch grab.kind {
        case .move:
            grab.rect = movedRect(grab.startRect, startMouse: grab.startMouse, mouse: point)
            grab.window.setAxFrame(grab.rect.topLeftCorner, nil)
        case .resize:
            // Tiling windows too: only the grabbed window follows live, the neighbours adjust on drop
            grab.rect = resizedRect(grab.startRect, corner: grab.corner, startMouse: grab.startMouse, mouse: point)
            grab.window.setAxFrame(grab.rect.topLeftCorner, grab.rect.size)
    }
    activeGrab = grab
    activePreview?.update(mouse: grab.mouse, rect: grab.rect)
}

@MainActor private func endMouseGrab(_ point: CGPoint) {
    updateMouseGrab(point, isFinalEvent: true)
    finishMouseGrab(drop: true)
}

@MainActor private func finishMouseGrab(drop: Bool) {
    guard let grab = activeGrab else { return }
    activeGrab = nil
    let preview = activePreview
    activePreview = nil
    grabWatchdogTask?.cancel()
    grabWatchdogTask = nil
    setGrabbedWithMouseNativeWindowId(nil)
    let token: RunSessionGuard? = .isServerEnabled
    let previousGrabEnd = grabEndTask
    grabEndTask = Task.startUnstructured { @MainActor in
        @MainActor func applyAndCleanUp() {
            if drop {
                applyDrop(grab, isPreviewed: preview != nil)
            } else {
                preview?.restore()
            }
            if preview != nil, grab.window.lifeStatus == .alive {
                // The window is where the grab left it, not in the slot. Lets the layout animate it into the slot
                grab.window.lastAppliedLayoutPhysicalRect = grab.rect
            }
            // A new grab might have started in the meantime
            if activeGrab == nil {
                currentlyManipulatedWithMouseWindowId = nil
                resetTilingResizeWeightBaseline()
            }
        }
        if let preview {
            // The previous grab may still be putting its preview back. Only its completion matters
            _ = await previousGrabEnd?.result
            await preview.stop()
        }
        if let token {
            try await runLightSession(.mouseGrab, token, layoutAnimation: preview != nil ? .mouseGrab : LayoutAnimation.none) { applyAndCleanUp() }
        } else {
            applyAndCleanUp()
        }
    }
}

@MainActor private func applyDrop(_ grab: MouseGrab, isPreviewed: Bool) {
    let window = grab.window
    guard window.lifeStatus == .alive else { return }
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            if grab.kind == .resize {
                window.lastFloatingSize = grab.rect.size
            }
            rebindFloatingWindowToMonitorUnder(window, center: grab.rect.center)
        case .tilingContainer:
            // Without the preview, the neighbours stay in place during the drag, the tree changes only once, on drop.
            // With it, the drop only catches up with the last mouse event
            switch grab.kind {
                case .move:
                    resolveTilingDrop(window, at: grab.mouse, targetWorkspace: grab.mouse.monitorApproximation.visibleWorkspace)
                        .apply(to: window)
                case .resize:
                    // A native resize that never got its mouse-up could have left a stale baseline.
                    // The preview resets it at the grab start, and its baseline must survive until the drop
                    if !isPreviewed { resetTilingResizeWeightBaseline() }
                    applyTilingWindowResize(window, from: grab.startRect, to: grab.rect)
            }
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer, nil:
            return
    }
}

/// The swallowed button-up might never come (e.g. Mission Control or the lock screen took the mouse),
/// so the grab can't rely on the tap alone to end
@MainActor private func startGrabWatchdog() {
    grabWatchdogTask?.cancel()
    grabWatchdogTask = Task.startUnstructured { @MainActor in
        while true {
            try await Task.sleep(for: .milliseconds(250))
            guard let grab = activeGrab else { return }
            if !isStillValid(grab) {
                cancelMouseGrab()
                return
            }
        }
    }
}

@MainActor private func isStillValid(_ grab: MouseGrab, isFinalEvent: Bool = false) -> Bool {
    isMouseGrabStillValid(
        isWindowGrabbable: grab.window.lifeStatus == .alive &&
            grab.window.nodeWorkspace?.isVisible == true &&
            !grab.window.isHiddenInCorner &&
            monitorsFingerprint() == grab.monitors,
        isButtonPressed: isPhysicallyPressed(grab.button),
        isFinalEvent: isFinalEvent,
    )
}

/// `.hidSystemState` is the hardware state, unaffected by the swallowed events and by other taps
private func isPhysicallyPressed(_ button: MouseButton) -> Bool {
    let cgButton: CGMouseButton = switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
    }
    return CGEventSource.buttonState(.hidSystemState, button: cgButton)
}

@MainActor private func monitorsFingerprint() -> [CGRect] {
    globalUnsortedMonitorInfos.map { CGRect(x: $0.rect.topLeftX, y: $0.rect.topLeftY, width: $0.rect.width, height: $0.rect.height) }
}

/// Front-to-back hit-test without AX requests, which can be slow for unresponsive apps.
/// Windows that HyprMac doesn't manage (overlays, borders, menus) are skipped
@MainActor private func managedWindowUnder(_ point: CGPoint) -> (Window, UInt32, Rect)? {
    let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
    guard let windowInfos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [NSDictionary] else { return nil }
    for info in windowInfos {
        guard let nativeWindowId = (info[kCGWindowNumber] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
              let rawBounds = info[kCGWindowBounds] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds),
              bounds.contains(point)
        else { continue }
        // Unlike the other overlays, the `[tab-bar]` takes the clicks: they are on the bar, not on a window below it
        // (e.g. a floating one). So a mouse binding on a bar grabs nothing, like a mouse binding on the desktop
        if pid == myPid && tabBarManager.isTabBar(at: point) { return nil }
        guard let window = Window.get(byNativeId: nativeWindowId, pid: pid) else { continue }
        return (window, nativeWindowId, Rect(topLeftX: bounds.minX, topLeftY: bounds.minY, width: bounds.width, height: bounds.height))
    }
    return nil
}
