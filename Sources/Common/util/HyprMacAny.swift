import Foundation
import AppKit

public protocol HyprMacAny {}

extension HyprMacAny {
    @discardableResult
    @inlinable
    public func apply(_ block: (Self) -> Void) -> Self {
        block(self)
        return self
    }

    @discardableResult
    @inlinable
    public func also(_ block: (Self) -> Void) -> Self {
        block(self)
        return self
    }

    @inlinable public func takeIf(_ predicate: (Self) -> Bool) -> Self? { predicate(self) ? self : nil }
    @inlinable public func then<R>(_ body: (Self) -> R) -> R { body(self) }

    var noopKeyPath: () {
        get { () }
        set {} // swiftlint:disable:this unused_setter_value
    }
}

extension Int: HyprMacAny {}
extension String: HyprMacAny {}
extension Character: HyprMacAny {}
extension Regex: HyprMacAny {}
extension Array: HyprMacAny {}
extension URL: HyprMacAny {}
extension CGFloat: HyprMacAny {}
extension AXUIElement: HyprMacAny {}
extension CGPoint: HyprMacAny {}
