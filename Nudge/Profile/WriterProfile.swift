import Foundation

/// A tone the writer can set as their default, or for one app or website.
enum Tone: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case friendly
    case casual
    case formal
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No preference"
        case .friendly: "Friendly"
        case .casual: "Casual"
        case .formal: "Formal"
        case .direct: "Direct"
        }
    }

    var phrase: String? {
        switch self {
        case .none: nil
        case .friendly: "warm and friendly"
        case .casual: "casual and relaxed"
        case .formal: "formal and professional"
        case .direct: "direct and to the point"
        }
    }
}

enum Formality: String, Codable, CaseIterable, Identifiable, Sendable {
    case relaxed
    case balanced
    case formal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relaxed: "Relaxed"
        case .balanced: "In between"
        case .formal: "Formal"
        }
    }

    var phrase: String {
        switch self {
        case .relaxed: "usually relaxed, not formal"
        case .balanced: "usually somewhere between relaxed and formal"
        case .formal: "usually formal"
        }
    }
}

enum EnglishVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    case uk
    case us
    case australia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uk: "UK English"
        case .us: "US English"
        case .australia: "Australian English"
        }
    }

    var rule: String {
        switch self {
        case .uk: "Use UK English spelling, for example colour, organise, centre, realise."
        case .us: "Use US English spelling, for example color, organize, center, realize."
        case .australia: "Use Australian English spelling, for example colour, organise, centre, realise."
        }
    }
}

/// A tone for one app (by bundle ID) or one website (by host name).
struct Voice: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case app
        case site
    }

    var id = UUID()
    var kind: Kind
    /// Bundle ID for an app, host name for a website.
    var key: String
    var name: String
    var tone: Tone
}

/// Everything Nudge knows about how the user writes.
/// Stored only on this Mac, in Application Support. Never sent anywhere.
struct WriterProfile: Codable, Equatable, Sendable {
    var name = ""
    var role = ""
    var tone: Tone = .none
    var formality: Formality = .balanced
    var language: EnglishVariant = .uk
    var preferredPhrases: [String] = []
    var signOffs: [String] = []
    var avoidWords: [String] = []
    var samples: [String] = []
    var voices: [Voice] = []
    var hasCompletedOnboarding = false

    /// The most words of profile Nudge sends with each rewrite. The on-device
    /// model has a small context window.
    static let summaryWordLimit = 150

    /// The tone for a field: a website's voice first, then the app's, then the default.
    func voice(bundleID: String?, site: String?) -> (tone: Tone, source: String)? {
        if let site, let voice = voices.first(where: { $0.kind == .site && Self.host(site, matches: $0.key) }),
           voice.tone != .none {
            return (voice.tone, voice.name)
        }
        if let bundleID, let voice = voices.first(where: { $0.kind == .app && $0.key == bundleID }),
           voice.tone != .none {
            return (voice.tone, voice.name)
        }
        return tone == .none ? nil : (tone, "default")
    }

    private static func host(_ host: String, matches key: String) -> Bool {
        let host = host.lowercased()
        let key = key.lowercased()
        return host == key || host.hasSuffix("." + key)
    }

    /// The compact description of the writer that goes into the prompt.
    /// - Parameters:
    ///   - action: nil for a custom instruction.
    ///   - tone: the voice for this field, used only by actions that have no tone of their own.
    func summary(for action: RewriteAction?, tone: Tone?) -> String? {
        var required: [String] = []
        var optional: [String] = []

        // Fix only changes spelling and grammar, so it only needs the spelling rule.
        if action == .fix {
            return "About the writer:\n- \(language.rule)"
        }

        let who = [name, role].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !who.isEmpty {
            required.append("- \(who.joined(separator: ", ")).")
        }
        // Formal, Casual and the rest set their own tone. Custom instructions too.
        let actionHasOwnTone = action == nil || [.formal, .casual, .friendly, .direct].contains(action)
        if !actionHasOwnTone {
            if let tone, let phrase = tone.phrase {
                // An app or website voice replaces the usual formality, so the two never clash.
                let isUsualTone = tone == self.tone
                required.append(isUsualTone ? "- Tone: \(phrase), \(formality.phrase)." : "- Tone: \(phrase).")
            } else {
                required.append("- Tone: \(formality.phrase).")
            }
        }
        required.append("- \(language.rule)")
        let avoid = Self.clean(avoidWords)
        if !avoid.isEmpty {
            required.append("- Never use these words or phrases: \(avoid.joined(separator: ", ")).")
        }
        let phrases = Self.clean(preferredPhrases)
        if !phrases.isEmpty {
            optional.append("- Phrases they like, to use only where they fit naturally: \(phrases.joined(separator: ", ")).")
        }
        let endings = Self.clean(signOffs)
        if !endings.isEmpty {
            optional.append("- If the text already ends with a sign-off, use one of theirs: \(endings.joined(separator: ", ")).")
        }
        for sample in Self.clean(samples).prefix(2) {
            let short = Self.firstWords(sample, 40)
            optional.append("- Example of how they write (match the voice only, never copy the content): \"\(short)\"")
        }

        // Keep within the word limit by dropping the least important lines last-in first-out.
        var lines = required + optional
        while Self.wordCount(lines) > Self.summaryWordLimit, lines.count > required.count {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }
        return "About the writer, so the result sounds like them:\n" + lines.joined(separator: "\n")
    }

    /// Lines Nudge may keep at the end of a rewrite when the original ended with a sign-off.
    var signOffWords: [String] {
        let name = name.trimmingCharacters(in: .whitespaces)
        return Self.clean(signOffs) + (name.isEmpty ? [] : [name] + name.split(separator: " ").prefix(1).map(String.init))
    }

    static func clean(_ items: [String]) -> [String] {
        items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func wordCount(_ lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
    }

    private static func firstWords(_ text: String, _ limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let flat = words.prefix(limit).joined(separator: " ")
        return words.count > limit ? flat + "…" : flat
    }
}
