import Cocoa
import ApplicationServices

enum Accessibility {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var children: [AXUIElement] { attribute(kAXChildrenAttribute) ?? [] }
    var role: String? { attribute(kAXRoleAttribute) }
    var title: String? { attribute(kAXTitleAttribute) }
    var identifier: String? { attribute(kAXIdentifierAttribute) }

    var position: CGPoint? {
        guard let value: AXValue = axValue(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let value: AXValue = axValue(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    /// Frame in AX (top-left origin, global) coordinates.
    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }

    private func axValue(_ name: String) -> AXValue? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The screen containing a point in AX/CoreGraphics (top-left origin) global coordinates.
    static func containing(globalPoint point: CGPoint) -> NSScreen? {
        let cocoaPoint = CGRect(origin: point, size: .zero).flippedToCocoa.origin
        return screens.first { NSMouseInRect(cocoaPoint, $0.frame, false) }
    }

    /// The screen under the mouse cursor.
    static var underMouse: NSScreen? {
        screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
    }
}

extension CGRect {
    /// Converts a rect between AX/CoreGraphics (top-left origin) and Cocoa (bottom-left origin) global coordinates.
    var flippedToCocoa: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }
}
