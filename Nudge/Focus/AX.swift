import ApplicationServices
import CoreGraphics

/// Small typed wrappers over the C Accessibility API.
enum AX {
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        elementResult(element, attribute).element
    }

    /// Keep the AX error separate from a successful response without an element.
    static func elementResult(_ element: AXUIElement, _ attribute: String)
        -> (element: AXUIElement?, diagnostic: String) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return (nil, "AXError \(error.rawValue) (\(error))")
        }
        guard let value else { return (nil, "success, no value") }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (nil, "success, unexpected value type \(CFGetTypeID(value))")
        }
        return ((value as! AXUIElement), "success")
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    static func hasAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else {
            return false
        }
        return list.contains(attribute)
    }

    /// Frame in Accessibility coordinates: origin at the top-left of the
    /// primary screen, y grows downward.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element), let size = size(element) else { return nil }
        return validFrame(origin: origin, size: size)
    }

    /// Other apps can report infinite, NaN or absurd numbers. Turning those
    /// into an Int, or a window position, crashes Nudge, so they stop here.
    static func validFrame(origin: CGPoint, size: CGSize) -> CGRect? {
        let numbers = [origin.x, origin.y, size.width, size.height]
        guard numbers.allSatisfy({ $0.isFinite && abs($0) < 1e9 }) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Other apps use NSNotFound (Int.max) for "no range". Adding to it overflows.
    static func validRange(_ range: CFRange) -> CFRange? {
        let limit = Int(Int32.max)
        guard (0...limit).contains(range.location), (0...limit).contains(range.length) else { return nil }
        return range
    }

    static func url(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! CFURL) as URL }
        return (value as? String).flatMap(URL.init(string:))
    }

    static func setString(_ element: AXUIElement, _ attribute: String, _ value: String) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFString)
    }

    /// A text range, in UTF-16 units, such as kAXSelectedTextRangeAttribute.
    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &result) ? validRange(result) : nil
    }

    /// Where a range of text is drawn, in Accessibility coordinates.
    static func bounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
        guard let value = parameterized(element, kAXBoundsForRangeParameterizedAttribute, range),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return validFrame(origin: rect.origin, size: rect.size)
    }

    static func string(_ element: AXUIElement, range: CFRange) -> String? {
        parameterized(element, kAXStringForRangeParameterizedAttribute, range) as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    /// How long a field's text is, without reading the text.
    static func characterCount(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Int
    }

    private static func parameterized(_ element: AXUIElement, _ attribute: String, _ range: CFRange) -> CFTypeRef? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success else {
            return nil
        }
        return value
    }

    @discardableResult
    static func setRange(_ element: AXUIElement, _ attribute: String, _ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// The app's currently focused element, read fresh.
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return element(app, kAXFocusedUIElementAttribute)
    }

    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef)
    }

    private static func point(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &result) ? result : nil
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &result) ? result : nil
    }
}
