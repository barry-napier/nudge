import Foundation

/// Removes wrapping that Apple's small model adds despite its instructions:
/// tags, code fences, "Sure, here is…" openers, wrapping quotes, and
/// sign-offs or [Your Name] placeholders the writer never wrote.
enum OutputCleaner {
    static func clean(_ raw: String, original: String) -> String {
        var text = raw
            .replacingOccurrences(of: "<text>", with: "")
            .replacingOccurrences(of: "</text>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = removeCodeFence(text)
        text = removeOpener(text, original: original)
        text = removeAddedEnding(text, original: original)
        text = removeWrappingQuotes(text, original: original)
        return text
    }

    private static func removeCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 else { return text }
        var inner = String(text.dropFirst(3).dropLast(3))
        if let newline = inner.firstIndex(of: "\n"), !inner[..<newline].contains(" ") {
            inner = String(inner[inner.index(after: newline)...])  // a language tag
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Sure! Here is the text rewritten to be direct:" and the like.
    private static func removeOpener(_ text: String, original: String) -> String {
        guard let newline = text.firstIndex(of: "\n") else { return text }
        let first = text[..<newline].trimmingCharacters(in: .whitespaces).lowercased()
        let opensLikeReply = first.hasPrefix("sure") || first.hasPrefix("here is") || first.hasPrefix("here's")
            || first.hasPrefix("certainly") || first.hasPrefix("of course")
        let talksAboutText = ["text", "version", "rewrite", "rewritten", "edited", "corrected", "revised"]
            .contains { first.contains($0) }
        let isOpener = (opensLikeReply && (talksAboutText || first.hasSuffix(":")))
            || (first.hasSuffix(":") && talksAboutText)
        guard isOpener, !original.lowercased().hasPrefix(first) else { return text }
        return String(text[newline...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let signOffs: Set<String> = [
        "best", "best regards", "best wishes", "kind regards", "warm regards", "regards",
        "many thanks", "thanks", "thank you", "thanks so much", "cheers", "sincerely",
        "yours sincerely", "yours faithfully", "all the best", "see you later", "talk soon",
        "take care",
    ]

    /// Drops trailing placeholder and sign-off lines the original did not have.
    private static func removeAddedEnding(_ text: String, original: String) -> String {
        let originalLower = original.lowercased()
        var text = text
        // An inline placeholder first, for example "Best, [Your Name]".
        if !original.contains("[") {
            text = text.replacingOccurrences(
                of: #"[ \t]*\[(your|my|sender'?s?)[^\]]*\]"#, with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.removeLast()
                continue
            }
            let isPlaceholder = trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !original.contains("[")
            let bare = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!"))
            let isAddedSignOff = signOffs.contains(bare) && !originalLower.contains(bare)
            guard isPlaceholder || isAddedSignOff else { break }
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeWrappingQuotes(_ text: String, original: String) -> String {
        var text = text
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("`", "`")]
        for (open, close) in pairs where text.count >= 2 && text.first == open && text.last == close {
            if !(original.first == open && original.last == close) {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}
