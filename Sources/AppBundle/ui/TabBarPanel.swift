import AppKit
import Common
import SwiftUI

/// The overlay of a `[tab-bar]`. HyprMac never manages its own windows (see ``MacApp/getOrRegister(_:)``),
/// so the bar is neither laid out nor focused like an app window
final class TabBarNSPanel: NSPanel, TabBarPanel {
    private let model = TabBarViewModel()

    init(onSelect: @escaping @MainActor (OpaqueWindowId) -> Void) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        // Not floating: the bar must not cover the windows of other apps that overlap it
        level = .normal
        // No canJoinAllSpaces: the bar belongs to the Space of the windows it's above
        collectionBehavior = [.stationary, .ignoresCycle]
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        contentView = FirstMouseHostingView(rootView: TabBarView(model: model, onSelect: onSelect))
    }

    // A click on a tab must not steal the keyboard focus from the window that the click focuses
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ state: TabBarState) {
        model.state = state
        setFrame(state.frame.cocoaFrame, display: true)
        // Regardless: HyprMac is never the active app
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        orderOut(nil)
    }
}

/// Without it, the first click on the panel of the inactive app would be eaten by the panel itself
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

@MainActor
private final class TabBarViewModel: ObservableObject {
    @Published var state: TabBarState? = nil
}

private struct TabBarView: View {
    @ObservedObject var model: TabBarViewModel
    let onSelect: @MainActor (OpaqueWindowId) -> Void

    var body: some View {
        if let state = model.state {
            let style = state.style
            HStack(spacing: 1) {
                ForEach(state.items, id: \.windowId) { item in
                    TabBarTab(item: item, style: style)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(item.windowId) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(style.backgroundColor.swiftUiColor)
        }
    }
}

private struct TabBarTab: View {
    let item: TabBarItem
    let style: TabBarConfig

    var body: some View {
        HStack(spacing: 4) {
            if style.showIcons, let icon = NSRunningApplication(processIdentifier: item.appPid)?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: CGFloat(style.fontSize) + 4, height: CGFloat(style.fontSize) + 4)
            }
            Text(item.title)
                .font(.system(size: CGFloat(style.fontSize)))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(style.textColor.swiftUiColor)
        .background((item.isActive ? style.activeColor : style.inactiveColor).swiftUiColor)
    }
}

extension ArgbColor {
    fileprivate var swiftUiColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}
