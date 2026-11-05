import AppKit
import Common

/// Where a window shown by scratchpad-toggle returns to when it's hidden
struct ScratchpadHome: Equatable {
    /// Stored by name rather than by reference, because the workspace is garbage collected once the scratchpad
    /// leaves it empty. Workspace.get(byName:) recreates it on hide
    let workspaceName: String
    let wasFloating: Bool
    let prevFocusedWindowId: OpaqueWindowId?
}

/// Frame relative to the monitor's visible rect, so that the window keeps its relative place and size when the
/// scratchpad is shown on monitors of different sizes
struct ScratchpadFrame: Equatable {
    let proportionalTopLeft: CGPoint
    let size: CGSize

    init(_ rect: Rect, relativeTo area: Rect) {
        proportionalTopLeft = CGPoint(
            x: area.width == 0 ? 0 : (rect.topLeftX - area.topLeftX) / area.width,
            y: area.height == 0 ? 0 : (rect.topLeftY - area.topLeftY) / area.height,
        )
        size = rect.size
    }

    func toRect(in area: Rect) -> Rect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        let x = (area.topLeftX + area.width * proportionalTopLeft.x).coerce(in: area.minX ... area.maxX - width)
        let y = (area.topLeftY + area.height * proportionalTopLeft.y).coerce(in: area.minY ... area.maxY - height)
        return Rect(topLeftX: x, topLeftY: y, width: width, height: height)
    }
}

/// Windows that are currently shown as a scratchpad on a workspace other than their home
@MainActor var scratchpadShownWindows: [OpaqueWindowId: ScratchpadHome] = [:]
/// The last floating frame of a scratchpad window. Kept after hide, so that the next show reuses it
@MainActor var scratchpadFrames: [OpaqueWindowId: ScratchpadFrame] = [:]

/// Lays the workspaces out once a scratchpad window slid out of the screen, so that the hide loop hides it in the corner.
/// Tests replace it, because sessions need real apps
@MainActor var onScratchpadSlideOutLanded: @MainActor () -> Void = { scheduleCancellableCompleteRefreshSession(.slideOutLanded) }

/// nil when the scratchpad windows appear and disappear right away
@MainActor var scratchpadSlide: (style: FrameAnimationStyle, direction: ScratchpadSlideDirection)? {
    let animation = config.animations.scratchpad
    return animation.isEnabled ? (animation.style, animation.direction) : nil
}

extension Rect {
    /// The rect moved just outside the monitor, on the side the scratchpad slides from and to
    func pushedOut(of monitorRect: Rect, _ direction: ScratchpadSlideDirection) -> Rect {
        switch direction {
            case .bottom: Rect(topLeftX: topLeftX, topLeftY: monitorRect.maxY, width: width, height: height)
            case .left: Rect(topLeftX: monitorRect.minX - width, topLeftY: topLeftY, width: width, height: height)
            case .right: Rect(topLeftX: monitorRect.maxX, topLeftY: topLeftY, width: width, height: height)
        }
    }
}

@MainActor
func forgetScratchpadState(windowId: OpaqueWindowId) {
    scratchpadShownWindows.removeValue(forKey: windowId)
    scratchpadFrames.removeValue(forKey: windowId)
}
