import AppKit
import Common

/// What the borders need to know about the window they surround
struct BorderTargetInfo: Equatable {
    /// Top-left coordinates, the same ones as the AX API
    let frame: Rect
    /// The raw value of `NSWindow.Level`
    let level: Int
}

/// The way the borders follow their windows. See ``SkyLightBorderWindowServer`` and ``PublicBorderWindowServer``
@MainActor
protocol BorderWindowServer: AnyObject {
    /// Whether the WindowServer tells about the moves of the windows by itself.
    /// Otherwise, the borders follow the frames that HyprMac writes and the AX notifications
    var notifiesWindowMoves: Bool { get }
    var placement: BorderPlacement { get }
    func targetInfo(_ windowId: UInt32) -> BorderTargetInfo?
    /// The corner radius of the window, nil when it's unknown
    func cornerRadius(_ windowId: UInt32) -> CGFloat?
    /// Whether the border is already right next to its window in the z-order, on the side of ``placement``
    func isOrderedNextTo(border: UInt32, target: UInt32) -> Bool
    /// The windows whose moves the WindowServer must report to ``SkyLight/windowEventHandler``
    func watch(_ windowIds: [UInt32])
}

/// Follows the windows like JankyBorders does: the WindowServer reports their moves and reorders. Each border sits right
/// next to its window in the z-order (AppKit orders it, see ``BorderOverlay/reorder(nextTo:)``), so other windows that
/// overlap the window overlap its border as well
@MainActor
final class SkyLightBorderWindowServer: BorderWindowServer {
    private let skyLight: SkyLight

    init(_ skyLight: SkyLight) { self.skyLight = skyLight }

    var notifiesWindowMoves: Bool { true }
    var placement: BorderPlacement { config.borders.order == .above ? .rightAboveWindow : .belowWindow }

    func targetInfo(_ windowId: UInt32) -> BorderTargetInfo? {
        guard let bounds = skyLight.windowBounds(windowId), let level = skyLight.windowLevel(windowId) else { return nil }
        return BorderTargetInfo(frame: bounds.topLeftRect, level: level)
    }

    func cornerRadius(_ windowId: UInt32) -> CGFloat? { skyLight.cornerRadius(of: windowId) }


    func isOrderedNextTo(border: UInt32, target: UInt32) -> Bool {
        let above = placement == .rightAboveWindow
        let option: CGWindowListOption = above ? .optionOnScreenAboveWindow : .optionOnScreenBelowWindow
        guard let infos = CGWindowListCopyWindowInfo(option, target) as? [[CFString: Any]] else { return false }
        // The list goes from front to back: the window right above the target is the last one,
        // the window right below it is the first one
        let neighbour = above ? infos.last : infos.first
        return (neighbour?[kCGWindowNumber] as? NSNumber)?.uint32Value == border
    }

    func watch(_ windowIds: [UInt32]) {
        if !skyLight.requestNotifications(for: windowIds) {
            reportBordersProblem("SkyLight refused to report the moves of the windows. The borders only follow the moves made by HyprMac")
        }
    }
}

/// The fallback when SkyLight lacks one of the symbols. Without the WindowServer notifications, the borders can't
/// follow the reorders of the windows, so they float above all normal windows: a border may cover a floating window
/// that overlaps its own window
@MainActor
final class PublicBorderWindowServer: BorderWindowServer {
    var notifiesWindowMoves: Bool { false }
    var placement: BorderPlacement { .aboveWindow }

    func targetInfo(_ windowId: UInt32) -> BorderTargetInfo? {
        guard let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[CFString: Any]],
              let info = infos.first,
              let boundsDict = info[kCGWindowBounds],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary),
              let level = info[kCGWindowLayer] as? Int
        else { return nil }
        return BorderTargetInfo(frame: bounds.topLeftRect, level: level)
    }

    /// Public APIs don't tell the corner radius of windows
    func cornerRadius(_ windowId: UInt32) -> CGFloat? { nil }
    /// The borders float above all the windows, there is nothing to keep in order
    func isOrderedNextTo(border: UInt32, target: UInt32) -> Bool { true }
    func watch(_ windowIds: [UInt32]) {}
}

extension CGRect {
    /// For the rects that are already in the top-left coordinates. ``toRect()`` mixes up minY and maxY
    fileprivate var topLeftRect: Rect { Rect(topLeftX: minX, topLeftY: minY, width: width, height: height) }
}

enum BorderWindowServerSelection {
    case skyLight(SkyLight)
    /// The reason is shown to the user once
    case publicApi(reason: String)
}

let publicBorderWindowServerLimitations = """

    The borders fall back to public APIs, with these limitations:
    - a border may cover a floating window that overlaps its own window;
    - a border may lag behind its window while the window is dragged.
    """

@MainActor
func selectBorderWindowServer(_ resolver: SkyLightSymbolResolver?) -> BorderWindowServerSelection {
    switch unsafe loadSkyLight(resolver) {
        case .loaded(let skyLight):
            .skyLight(skyLight)
        case .frameworkUnavailable:
            .publicApi(reason: "Can't open \(skyLightPath).")
        case .missingSymbols(let symbols):
            .publicApi(reason: "SkyLight lacks \(symbols.joined(separator: ", ")). Probably, a macOS update removed them.")
    }
}

@MainActor private var reportedBordersProblems: Set<String> = []

/// Once per problem and per HyprMac run: the borders keep working in a degraded way, nagging wouldn't help
@MainActor
func reportBordersProblem(_ problem: String) {
    if !reportedBordersProblems.insert(problem).inserted { return }
    MessageModel.shared.message = Message(
        description: "HyprMac Borders",
        body: "\(problem)\n\nSee https://github.com/NovaisVictor/HyprMac/blob/main/docs/guide.adoc#borders",
        containsWarnings: true,
    )
}
