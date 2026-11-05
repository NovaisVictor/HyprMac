import AppKit
import Common

struct FloatingFrameCommand: Command {
    let args: FloatingFrameCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard window.isFloating else { return .fail(io.err(notFloatingWindowMsg)) }

        let current: Rect?
        if args.needsCurrentFrame {
            do {
                current = try await window.getUnhiddenFloatingRect(.nonCancellable)
            } catch {
                return .fail(io.err("Can't get the current frame of window \(window.windowId): \(error)"))
            }
            if current == nil {
                return .fail(io.err("Can't get the current frame of window \(window.windowId)"))
            }
        } else {
            current = nil
        }

        // Check again, the window could have been re-bound during the suspension point above
        guard window.isFloating, let workspace = window.nodeWorkspace else { return .fail(io.err(notFloatingWindowMsg)) }
        // The workspace monitor is known as soon as the window is bound to a workspace, unlike the AX rect that may lag
        // behind (e.g. in on-window-detected callbacks). That's why it's used as the reference instead of the AX rect
        let reference = workspace.visibleRectPaddedByOuterGaps

        window.setFloatingFrame(args.resolveFrame(reference: reference, current: current))
        return .succ
    }
}

private let notFloatingWindowMsg = "floating-frame only supports floating windows. Tip: use 'layout floating' first"

extension FloatingFrameCmdArgs {
    /// Whether the omitted parts of the frame have to be taken from the current window frame
    fileprivate var needsCurrentFrame: Bool { size == nil || (position == nil && !center) }

    /// `current` must be non-nil if ``needsCurrentFrame`` is true
    fileprivate func resolveFrame(reference: Rect, current: Rect?) -> Rect {
        // Whole pixels make the result predictable, and the window can't be larger than the reference rect
        let width = (size.map { $0.width.resolve(reference.width) } ?? current.orDie().width).rounded()
            .coerce(in: 1 ... max(1, reference.width.rounded(.down)))
        let height = (size.map { $0.height.resolve(reference.height) } ?? current.orDie().height).rounded()
            .coerce(in: 1 ... max(1, reference.height.rounded(.down)))

        let topLeft: CGPoint = if center {
            reference.centered(CGSize(width: width, height: height)).topLeftCorner
        } else if let position {
            CGPoint(x: reference.topLeftX + position.x.resolve(reference.width), y: reference.topLeftY + position.y.resolve(reference.height))
        } else {
            current.orDie().topLeftCorner
        }

        // Keep the window fully inside the reference rect
        let x = topLeft.x.rounded().coerce(in: reference.minX ... max(reference.minX, reference.maxX - width))
        let y = topLeft.y.rounded().coerce(in: reference.minY ... max(reference.minY, reference.maxY - height))
        return Rect(topLeftX: x, topLeftY: y, width: width, height: height)
    }
}

extension FloatingFrameCmdArgs.Length {
    fileprivate func resolve(_ total: CGFloat) -> CGFloat {
        switch self {
            case .pixels(let value): CGFloat(value)
            case .percent(let value): total * CGFloat(value) / 100
        }
    }
}
