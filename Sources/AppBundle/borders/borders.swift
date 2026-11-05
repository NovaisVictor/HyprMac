import AppKit
import Common

/// nil while `[borders] enabled = false`: no window, no subscription, no work at all
@MainActor private(set) var bordersController: BordersController? = nil

/// Starts, restarts or stops the borders after a config reload
@MainActor
func syncBorders(_ config: Config) {
    let bordersConfig = config.borders
    guard bordersConfig.enabled && !serverArgs.isReadOnly else {
        stopBorders()
        return
    }
    // Every border window is built from the config. A changed config rebuilds them, which is rare enough
    if bordersController?.config == bordersConfig { return }
    stopBorders()
    let windowServer: any BorderWindowServer = switch unsafe selectBorderWindowServer(openSkyLightResolver()) {
        case .skyLight(let skyLight):
            makeSkyLightBorderWindowServer(skyLight)
        case .publicApi(let reason):
            fallbackBorderWindowServer(reason)
    }
    bordersController = BordersController(bordersConfig, windowServer: windowServer)
    refreshBorders()
}

@MainActor
private func makeSkyLightBorderWindowServer(_ skyLight: SkyLight) -> any BorderWindowServer {
    guard skyLight.registerWindowEventsOnce() else {
        return fallbackBorderWindowServer("SkyLight refused to report the moves of the windows.")
    }
    SkyLight.windowEventHandler = { event, nativeWindowId in bordersController?.onWindowServerEvent(event, nativeWindowId) }
    return SkyLightBorderWindowServer(skyLight)
}

@MainActor
private func fallbackBorderWindowServer(_ reason: String) -> any BorderWindowServer {
    reportBordersProblem(reason + publicBorderWindowServerLimitations)
    return PublicBorderWindowServer()
}

@MainActor
private func stopBorders() {
    bordersController?.disposeAll()
    bordersController = nil
    SkyLight.windowEventHandler = nil
}

/// Brings the borders in line with the tree, the focus and the visible workspaces.
/// Called at the end of every refresh session, once the layout is applied
@MainActor
func refreshBorders() {
    guard let bordersController else { return }
    var nativeWindowIds: [OpaqueWindowId: UInt32] = [:]
    for window in MacWindow.allWindows {
        if let nativeWindowId = window.macApp.nativeWindowId(of: window.windowId) {
            nativeWindowIds[window.windowId] = nativeWindowId
        }
    }
    let roles = borderRoles(
        focus: globalFocus.windowOrNil,
        showsInactive: bordersController.config.inactiveColor != nil,
        isHyprMacEnabled: TrayMenuModel.shared.isEnabled,
    )
    bordersController.reconcile(roles, nativeWindowIds: nativeWindowIds)
}

/// Every frame that HyprMac writes: the layout, the frame animator, the mouse grab
@MainActor
func bordersOnFrameWrite(_ window: Window, topLeft: CGPoint?, size: CGSize?) {
    guard let bordersController, !bordersController.notifiesWindowMoves else { return }
    bordersController.onFrameWrite(window.windowId, topLeft: topLeft, size: size)
}

/// The AX moved and resized notifications, including the echoes of HyprMac's own writes: an echo carries the frame
/// that the app has really applied, which may differ from the written one (e.g. a minimum size)
func bordersOnAxFrameChange(_ nativeWindowId: UInt32?) {
    guard let nativeWindowId else { return }
    Task.startUnstructured { @MainActor in
        guard let bordersController, !bordersController.notifiesWindowMoves else { return }
        bordersController.onAxFrameChange(nativeWindowId)
    }
}
