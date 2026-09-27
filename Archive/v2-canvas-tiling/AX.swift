import AppKit
import ApplicationServices

// Private but long-stable API used by every window manager (yabai, AeroSpace, Rectangle…)
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

// Window-server calls every macOS window manager uses to know which desktop (Space) is showing.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32
@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: Int32, _ display: CFString) -> UInt64

enum AX {
    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool {
        (attr(el, name) as NSNumber?)?.boolValue ?? false
    }

    static func position(_ el: AXUIElement) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success, let v else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success, let v else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func setPosition(_ el: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
    }

    static func setSize(_ el: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
        }
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(el, &wid) == .success && wid != 0 ? wid : nil
    }

    static func raise(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}

// MARK: - Geometry helpers (AX space: origin top-left of primary screen, y grows down)

extension NSScreen {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    var axFrame: CGRect { Self.toAX(frame) }
    var axVisibleFrame: CGRect { Self.toAX(visibleFrame) }

    static func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static var underMouse: NSScreen {
        let m = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(m, $0.frame, false) } ?? main ?? screens[0]
    }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    static func / (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x / k, y: a.y / k) }
    var length: CGFloat { hypot(x, y) }
}

extension CGRect {
    var mid: CGPoint { CGPoint(x: midX, y: midY) }
}
