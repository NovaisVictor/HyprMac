import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: OpaqueWindowId
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    /// A pseudotiled window keeps ``pseudoSize`` and is centered in its tiling slot. See ``pseudoTiledFrame(in:)``
    var isPseudoTiled: Bool = false
    /// Stays after pseudotiling is turned off, so that turning it back on restores the size
    var pseudoSize: CGSize? = nil
    var layoutReason: LayoutReason = .standard
    var lifeStatus: WindowLifeStatus = .alive
    /// Set by the preselect command. One-shot: the tiling placement of the next window clears it once it's used.
    /// Focus changes keep it. Transient, it isn't frozen
    var preselect: CardinalDirection? = nil

    @MainActor
    init(id: OpaqueWindowId, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: OpaqueWindowId) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor static func get(byNativeId nativeWindowId: UInt32, pid: pid_t) -> Window? {
        MacApp.allAppsMap[pid]?.opaqueWindowId(of: nativeWindowId).flatMap { get(byId: $0) }
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }

    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false }
    func getMacosWindowNativeState(_ cm: CancellationMode) async throws -> MacosWindowNativeState {
        if try await isMacosFullscreen(cm) { return .nativeFullscreen }
        if try await isMacosMinimized(cm) { return .nativeMinimized }
        return .normal
    }

    var isHiddenInCorner: Bool { die("Not implemented") }
    /// Must be called when the window is explicitly placed while it may be hidden in the corner.
    /// Otherwise, the next layout pass moves the window back to where it was before it was hidden
    @MainActor func forgetHiddenInCornerPosition() { die("Not implemented") }
    /// The window is about to slide out of the screen and be hidden in the corner once it lands.
    /// unhideFromCorner must restore `rect`, the frame it had before the slide, not the off-screen one it lands on
    @MainActor func rememberFrameToUnhide(_ rect: Rect, monitorRect: Rect) { die("Not implemented") }
    @MainActor func nativeFocus() { die("Not implemented") }
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    /// Every frame write stops the frame animation of the window, so that the animation never undoes it
    @MainActor final func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        frameAnimator.cancel(self)
        setNativeAxFrame(topLeft, size)
        bordersOnFrameWrite(self, topLeft: topLeft, size: size)
    }

    /// Only for the frame animator. Everything else calls ``setAxFrame(_:_:)``
    func setNativeAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }

    /// Only for the frame animator: the AX notifications caused by the next frame writes must be ignored
    @MainActor func expectAnimationEcho() {}

    /// The frame the floating window has when its workspace is visible.
    /// Differs from ``getAxRect(_:)`` while the window is hidden in a corner
    @MainActor func getUnhiddenFloatingRect(_ cm: CancellationMode) async throws -> Rect? { try await getAxRect(cm) }

    /// Moves and resizes the floating window.
    /// The frame becomes the remembered floating state, so hiding/unhiding the window and toggling the layout keep it
    @MainActor func setFloatingFrame(_ rect: Rect) {
        lastFloatingSize = rect.size
        setAxFrame(rect.topLeftCorner, rect.size)
    }
}

enum MacosWindowNativeState: Sendable {
    case normal
    case nativeMinimized
    case nativeFullscreen
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: WindowParentCases.Kind)
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case nil: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}

extension Window {
    /// The frame that the layout gives to the window in `slot`: the slot itself, unless the window is pseudotiled
    @MainActor func pseudoTiledFrame(in slot: Rect) -> Rect {
        guard isPseudoTiled, let pseudoSize else { return slot }
        return pseudoTiledRect(pseudoSize, in: slot)
    }
}

/// `size` centered in `slot`. A size that doesn't fit is scaled down, keeping its aspect ratio
func pseudoTiledRect(_ size: CGSize, in slot: Rect) -> Rect {
    var width = size.width
    var height = size.height
    if width > slot.width {
        height = height * slot.width / width
        width = slot.width
    }
    if height > slot.height {
        width = width * slot.height / height
        height = slot.height
    }
    return Rect(
        topLeftX: slot.topLeftX + (slot.width - width) / 2,
        topLeftY: slot.topLeftY + (slot.height - height) / 2,
        width: width,
        height: height,
    )
}
