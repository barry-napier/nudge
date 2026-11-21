import ApplicationServices
import Foundation

enum WriteMethod: String {
    case accessibility
    case paste
}

/// What to replace in the field.
enum WriteTarget {
    /// The whole field. `current` is its value, when known.
    case whole(current: String?)
    /// A selection. `range` is in UTF-16 units, when known. `old` is the text there now.
    case selection(range: CFRange?, old: String)
}

enum WriteError: LocalizedError {
    case unconfirmed

    var errorDescription: String? {
        "Nudge could not confirm the change. Check the text, and press Command-Z if it looks wrong."
    }
}

/// Puts new text into a field. It tries Accessibility first, then falls back
/// to pasting. Browsers and Electron apps go straight to pasting, because they
/// often ignore Accessibility writes and it breaks their undo.
@MainActor
enum TextWriter {
    static func replace(
        _ target: WriteTarget, with newText: String, in element: AXUIElement, preferPaste: Bool
    ) async throws -> WriteMethod {
        AXUIElementSetMessagingTimeout(element, 1.0)
        if !preferPaste, try writeWithAccessibility(target, newText, element) {
            return .accessibility
        }

        switch target {
        case .whole(let current):
            let value = current ?? AX.string(element, kAXValueAttribute) ?? ""
            let all = CFRange(location: 0, length: TextAccess.utf16Length(value))
            if !AX.setRange(element, kAXSelectedTextRangeAttribute, all) {
                KeyPoster.selectAll()
                await pause(milliseconds: 60)
            }
        case .selection(let range, _):
            if let range {
                AX.setRange(element, kAXSelectedTextRangeAttribute, range)
            }
        }
        await Clipboard.paste(newText)
        return .paste
    }

    /// True when the write is confirmed. False when nothing changed, so pasting
    /// is safe to try. Throws when the field changed in a way we cannot confirm.
    private static func writeWithAccessibility(
        _ target: WriteTarget, _ newText: String, _ element: AXUIElement
    ) throws -> Bool {
        let before = AX.string(element, kAXValueAttribute)

        switch target {
        case .whole:
            guard AX.isSettable(element, kAXValueAttribute),
                  AX.setString(element, kAXValueAttribute, newText) == .success else {
                return false
            }
            let after = AX.string(element, kAXValueAttribute)
            if after == newText { return true }
            if after == before { return false }
            throw WriteError.unconfirmed

        case .selection(let range, let old):
            if let range {
                AX.setRange(element, kAXSelectedTextRangeAttribute, range)
            }
            guard AX.setString(element, kAXSelectedTextAttribute, newText) == .success else {
                return false
            }
            let after = AX.string(element, kAXValueAttribute)
            if let before, let after, let range,
               TextAccess.substring(of: before, range: range) != nil {
                let expected = (before as NSString).replacingCharacters(
                    in: NSRange(location: range.location, length: range.length), with: newText)
                if after == expected { return true }
                if after == before { return false }
                throw WriteError.unconfirmed
            }
            if before != nil || after != nil {
                if after == before { return false }
                if let after, after.contains(newText) { return true }
                throw WriteError.unconfirmed
            }
            // The value cannot be read. Check whether the selection was replaced.
            let selectedNow = AX.string(element, kAXSelectedTextAttribute)
            return selectedNow != old
        }
    }
}
