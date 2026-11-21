import ApplicationServices
import Foundation

/// The text Nudge took from a field, before rewriting.
struct CapturedText {
    enum Mode: String {
        case selection
        case whole
    }

    let mode: Mode
    /// The text to rewrite: the selection, or the whole field.
    let text: String
    /// The selection range in UTF-16 units, when the app reports it.
    let range: CFRange?
    /// The whole field value, when the app reports it.
    let fullValue: String?
}

enum TextAccess {
    /// Reads the selected text if there is a selection, otherwise the whole field.
    static func capture(from element: AXUIElement) -> CapturedText? {
        let value = AX.string(element, kAXValueAttribute)
        let range = AX.range(element, kAXSelectedTextRangeAttribute)

        if let selected = AX.string(element, kAXSelectedTextAttribute), !selected.isEmpty {
            return CapturedText(mode: .selection, text: selected, range: range, fullValue: value)
        }
        // Some apps report the range but not the selected text.
        if let value, let range, range.length > 0, let selected = substring(of: value, range: range) {
            return CapturedText(mode: .selection, text: selected, range: range, fullValue: value)
        }
        guard let value else { return nil }
        return CapturedText(mode: .whole, text: value, range: nil, fullValue: value)
    }

    /// Text at a UTF-16 range, or nil if the range is out of bounds.
    static func substring(of text: String, range: CFRange) -> String? {
        let ns = text as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= ns.length else {
            return nil
        }
        return ns.substring(with: NSRange(location: range.location, length: range.length))
    }

    static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }
}
