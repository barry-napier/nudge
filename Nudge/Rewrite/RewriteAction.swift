/// The rewrite choices offered in the popover.
enum RewriteAction: String, CaseIterable, Identifiable, Sendable {
    case fix
    case concise
    case improve

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fix: "Fix spelling and grammar"
        case .concise: "Make concise"
        case .improve: "Improve writing"
        }
    }

    var logName: String {
        switch self {
        case .fix: "Fix"
        case .concise: "Concise"
        case .improve: "Improve"
        }
    }

    var symbol: String {
        switch self {
        case .fix: "checkmark.circle"
        case .concise: "arrow.down.right.and.arrow.up.left"
        case .improve: "wand.and.sparkles"
        }
    }

    /// The task given to the model. Tested against Apple's on-device model:
    /// it follows a concrete word limit far better than "make it shorter".
    func instruction(for text: String) -> String {
        switch self {
        case .fix:
            return "Fix spelling, grammar, punctuation and capitalisation only, including a capital letter at the start of each sentence and for the word I. Do not change the wording, tone or meaning in any other way. If there are no mistakes, return the text unchanged."
        case .concise:
            let words = text.split(whereSeparator: \.isWhitespace).count
            let limit = max(3, Int((Double(words) * 0.6).rounded()))
            return "Make the text more concise. Rewrite it in no more than \(limit) words (it has \(words) now). Remove filler, hedging, repetition and pleasantries that add no meaning. Keep every important fact, request, name and number, and keep the original tone. If it is already as short as it can be, return it unchanged."
        case .improve:
            return "Improve the writing so it reads clearly and naturally. Fix any mistakes. Keep the original meaning, tone and roughly the same length."
        }
    }

    var temperature: Double {
        switch self {
        case .fix: 0.1
        case .concise: 0.4
        case .improve: 0.5
        }
    }
}
