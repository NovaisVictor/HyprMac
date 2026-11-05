import AppKit
import Common

extension Workspace {
    /// See `frameAnimator` and ``RefreshSessionEvent/layoutAnimation``
    @MainActor
    func layoutWorkspace(animation: LayoutAnimation = .none) async throws { // todo revisit API
        if isEffectivelyEmpty { return }
        var context = LayoutContext(self, animation: animation)
        let rect = layoutRect(context)
        let physicalRect = Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY, width: rect.width, height: rect.height - 1)
        // The workspace moved to another monitor, or the gaps changed. Every window moves at once, and sliding all of
        // them across the screen is noise rather than a hint of what changed
        if lastAppliedLayoutPhysicalRect != physicalRect {
            context = LayoutContext(self, animation: .none)
        }
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, context)
        context.plannedMoves?.apply()
    }

    /// Unlike ``layoutWorkspace(animation:)``, doesn't read the frame of every floating window,
    /// which makes it cheap enough for every tick of a mouse resize preview
    @MainActor
    func layoutTilingWindows() async throws {
        if isEffectivelyEmpty { return }
        let context = LayoutContext(self, animation: .none)
        let rect = layoutRect(context)
        try await rootTilingContainer.layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, context)
    }

    // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
    // window on the upper monitor to take full width. The layouts use rect.height - 1 to resolve this problem
    // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
    @MainActor
    private func layoutRect(_ context: LayoutContext) -> Rect { context.resolvedGaps.outer.pad(workspaceMonitorInfo.visibleRect) }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .monitor(let it):
                try await it.getWorkspacesContainerOrCreate().getVisibleWorkspaceOrCreate(parent: it)
                    .layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .workspacesContainer: die()
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                // An animating floating window (the scratchpad slide) may be off its monitor on purpose.
                // Pulling it back would cancel the animation
                let windows = container.children.filterIsInstance(of: Window.self).filter { frameAnimator.target(of: $0) == nil }
                // todo make it parallel among different workspaces. Get rid of 'try await'
                let rects = try await windows.mapConcurrently { try await $0.getAxRect(.cancellable) } // Probably not idempotent
                // A floating window grabbed with the mouse must not be pulled back to its workspace monitor mid-gesture
                for (window, windowRect) in zip(windows, rects) where window.windowId != currentlyManipulatedWithMouseWindowId {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    window.layoutFloatingWindow(context, windowRect)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        // A window that changes monitor jumps: sliding across the monitor edge looks broken
                        let previousRect = lastAppliedLayoutPhysicalRect
                            .flatMap { context.workspace.workspaceMonitorInfo.rect.contains($0.center) ? $0 : nil }
                        // Always the slot, even for a pseudotiled window: dwindle placement, the mouse grab and
                        // the drop hit-testing work with slots
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.applyLayoutFrame(
                            window.pseudoTiledFrame(in: physicalRect),
                            previousRect: previousRect.map(window.pseudoTiledFrame),
                            context,
                        )
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                container.lastAppliedTabBarRect = nil // Only layoutAccordion knows whether the container still has a bar
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                    case .master:
                        try await container.layoutMaster(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps
    /// nil when the frames are applied right away
    let plannedMoves: PlannedMoves?

    @MainActor
    init(_ workspace: Workspace, animation: LayoutAnimation) {
        self.workspace = workspace
        // Smart gaps are applied on top of the gaps of the workspace rules
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps(for: workspace), workspace: workspace)
        self.plannedMoves = animation.style.map { PlannedMoves($0, maxAnimatedWindows: config.animations.maxWindows) }
    }
}

/// The animated frames of a layout pass are only applied once the whole pass is known,
/// because too many windows animating at once make all of them jump
@MainActor
private final class PlannedMoves {
    private let style: FrameAnimationStyle
    private let maxAnimatedWindows: Int
    private var moves: [(window: Window, from: Rect?, to: Rect)] = []

    init(_ style: FrameAnimationStyle, maxAnimatedWindows: Int) {
        self.style = style
        self.maxAnimatedWindows = maxAnimatedWindows
    }

    func plan(_ window: Window, from: Rect?, to: Rect) {
        moves.append((window, from, to))
    }

    func apply() {
        let animatedCount = moves.count { frameAnimator.wouldStartAnimation($0.window, from: $0.from, to: $0.to, style) }
        // Every frame of every animated window is an AX request to its app.
        // Past a point, the frames come late and the whole layout looks sluggish
        let jump = animatedCount > maxAnimatedWindows
        for (window, from, to) in moves {
            if jump {
                window.setAxFrame(to.topLeftCorner, to.size)
            } else {
                frameAnimator.animate(window, from: from, to: to, style)
            }
        }
    }
}

/// Which `[animations]` table animates the frames of a layout pass
enum LayoutAnimation: Equatable {
    case none, mouseGrab, windowsMove

    /// nil when the table is disabled
    @MainActor var style: FrameAnimationStyle? {
        switch self {
            case .none: nil
            case .mouseGrab:
                config.mouseGrab.livePreview && config.animations.mouseGrab.isEnabled ? config.animations.mouseGrab.style : nil
            case .windowsMove:
                // During a native drag or resize, the layout chases the mouse at the rate of the AX notifications.
                // Animating every step would only make the neighbours lag behind
                config.animations.windowsMove.isEnabled && currentlyManipulatedWithMouseWindowId == nil
                    ? config.animations.windowsMove.style
                    : nil
        }
    }
}

extension RefreshSessionEvent {
    /// The layout changes caused by commands and by windows that appear or go away animate.
    /// Startup and config reload don't: the windows jump from wherever they were before HyprMac laid them out.
    /// Spaces switching doesn't either: macOS already animates it
    var layoutAnimation: LayoutAnimation {
        switch self {
            case .mouseGrab: .mouseGrab
            case .hotkeyBinding, .socketServer, .menuBarButton, .tabBarClick, .ax, .windowTitleChanged: .windowsMove
            case .globalObserver(let notification):
                notification == NSWorkspace.activeSpaceDidChangeNotification.rawValue ? .none : .windowsMove
            // The window was dragged natively. It's under the mouse, not in the slot it would slide from
            case .globalObserverLeftMouseUp, .resetManipulatedWithMouse: .none
            case .startup, .focusFollowsMouse, .configAutoReload, .slideOutLanded: .none
        }
    }
}

extension Window {
    @MainActor
    fileprivate func applyLayoutFrame(_ rect: Rect, previousRect: Rect?, _ context: LayoutContext) {
        if let plannedMoves = context.plannedMoves {
            plannedMoves.plan(self, from: previousRect, to: rect)
        } else if frameAnimator.target(of: self) != rect {
            setAxFrame(rect.topLeftCorner, rect.size)
        }
        // Otherwise, the layout agrees with the running animation. Writing the frame now would make the window
        // jump to the end and back to the next animation frame
    }

    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext, _ windowRect: Rect?) {
        let workspace = context.workspace
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.visibleWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitorInfo.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let visibleRect = context.workspace.workspaceMonitorInfo.visibleRect
        let monitorRect = noOuterGapsInFullscreen ? visibleRect : context.resolvedGaps.outer.pad(visibleRect)
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        let inhabitedChildren = inhabitedChildren

        guard let delta = ((orientation == .h ? width : height) - CGFloat(inhabitedChildren.sumOfDouble { $0.getWeight(orientation) }))
            .div(inhabitedChildren.count) else { return }

        let lastIndex = inhabitedChildren.indices.last
        for (i, child) in inhabitedChildren.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    @MainActor
    fileprivate func layoutMaster(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let inhabitedChildren = inhabitedChildren
        let frames = masterLayoutFrames(
            width: width,
            height: height,
            orientation: orientation,
            ratio: effectiveMasterRatio,
            placement: effectiveMasterPlacement,
            count: inhabitedChildren.count,
            innerGaps: context.resolvedGaps.inner,
        )
        for (child, frame) in zip(inhabitedChildren, frames) {
            try await child.layoutRecursive(
                point + frame.physical.topLeftCorner,
                width: frame.physical.width,
                height: frame.physical.height,
                virtual: Rect(
                    topLeftX: virtual.topLeftX + frame.virtual.topLeftX,
                    topLeftY: virtual.topLeftY + frame.virtual.topLeftY,
                    width: frame.virtual.width,
                    height: frame.virtual.height,
                ),
                context,
            )
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let inhabitedChildren = inhabitedChildren

        guard let mruIndex: Int = mostRecentInhabitedChild?.ownIndex(in: .inhabitedOnly) else { return }
        let tabBar = config.tabBar
        var point = point
        var height = height
        if tabBar.enabled {
            lastAppliedTabBarRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: CGFloat(tabBar.height))
            point = point.addingYOffset(tabBar.reservedHeight)
            height = max(0, height - tabBar.reservedHeight)
        }
        // The tabs already show the other windows. The padding would only show slivers of them under the bar
        let padding = tabBar.enabled ? 0 : CGFloat(config.accordionPadding)
        for (index, child) in inhabitedChildren.enumerated() {
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where inhabitedChildren.count == 1: (0, 0)
                case 0:                                (0, padding)
                case inhabitedChildren.indices.last:   (padding, 0)
                case mruIndex - 1:                     (0, 2 * padding)
                case mruIndex + 1:                     (2 * padding, 0)
                default:                               (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }
}
