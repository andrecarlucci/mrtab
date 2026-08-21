import AppKit
import ApplicationServices
import Foundation

/// A hashable wrapper around `AXUIElement` so windows can live in sets/dictionaries.
/// `AXUIElement` is a CoreFoundation type, so identity is `CFEqual`, not pointer equality.
struct AXRef: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: AXRef, rhs: AXRef) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

@inline(__always)
func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

@inline(__always)
func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axCopy(element, attribute) as? String
}

@inline(__always)
func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    axCopy(element, attribute) as? Bool
}

func axChildElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    guard let raw = axCopy(element, attribute) as? [AnyObject] else { return [] }
    return raw.compactMap { child in
        CFGetTypeID(child) == AXUIElementGetTypeID() ? (child as! AXUIElement) : nil
    }
}

/// Reads `AXPosition` + `AXSize` as a screen-space rect (top-left origin, matching CGWindow bounds).
func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = axCopy(element, kAXPositionAttribute as String),
          let sizeValue = axCopy(element, kAXSizeAttribute as String),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }

    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

func axPID(of element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
}

extension AXUIElement {
    /// Caps how long a single AX round-trip may block. Without this an app that is beachballing
    /// stalls the refresh thread for the system default of 6 seconds.
    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(self, seconds)
    }
}

@inline(__always)
func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axCopy(element, attribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

extension NSImage {
    /// Renders a template image through a solid colour.
    func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect)
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        return result
    }
}
