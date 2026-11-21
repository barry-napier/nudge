/// The preset rewrite choices offered in the menu.
enum RewriteAction: String, CaseIterable, Identifiable, Sendable {
    case fix
    case concise
    case improve
    case formal
    case casual
    case friendly
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fix: "Fix spelling and grammar"
        case .concise: "Make concise"
        case .improve: "Improve writing"
        case .formal: "Formal"
        case .casual: "Casual"
        case .friendly: "Friendly"
        case .direct: "Direct"
        }
    }

    var logName: String {
        switch self {
        case .fix: "Fix"
        case .concise: "Concise"
        case .improve: "Improve"
        case .formal: "Formal"
        case .casual: "Casual"
        case .friendly: "Friendly"
        case .direct: "Direct"
        }
    }

    var symbol: String {
        switch self {
        case .fix: "checkmark.circle"
        case .concise: "arrow.down.right.and.arrow.up.left"
        case .improve: "wand.and.sparkles"
        case .formal: "briefcase"
        case .casual: "cup.and.saucer"
        case .friendly: "face.smiling"
        case .direct: "arrow.right.circle"
        }
    }

    /// The task given to the model. Tested against Apple's on-device model:
    /// it follows a concrete word limit far better than "make it shorter".
    func instruction(for text: String) -> String {
        let keep = "Fix any mistakes. Keep the meaning and every fact, name and number. Keep roughly the same length."
        switch self {
        case .fix:
            return "Fix spelling, grammar, punctuation and capitalisation only, including a capital letter at the start of each sentence and for the word I. Do not change the wording, tone or meaning in any other way. If there are no mistakes, return the text unchanged."
        case .concise:
            let words = text.split(whereSeparator: \.isWhitespace).count
            let limit = max(3, Int((Double(words) * 0.6).rounded()))
            return "Make the text more concise. Rewrite it in no more than \(limit) words (it has \(words) now). Remove filler, hedging, repetition and pleasantries that add no meaning. Keep every important fact, request, name and number, and keep the original tone. If it is already as short as it can be, return it unchanged."
        case .improve:
            return "Improve the writing so it reads clearly and naturally. Fix any mistakes. Keep the original meaning, tone and roughly the same length."
        case .formal:
            return "Rewrite the text in a formal, professional tone. \(keep)"
        case .casual:
            return "Rewrite the text in a relaxed, casual tone, like a message to a colleague you know well. \(keep)"
        case .friendly:
            return "Rewrite the text in a warm, friendly tone. \(keep)"
        case .direct:
            return "Rewrite the text to be direct and to the point. Put the main point or request first. Remove hedging such as I think, maybe, just and sort of. Fix any mistakes. Keep every fact, name and number."
        }
    }

    var temperature: Double {
        switch self {
        case .fix: 0.1
        case .concise, .formal, .direct: 0.4
        case .improve, .casual, .friendly: 0.5
        }
    }
}

/// One rewrite job: a preset action, or a one-off instruction the user typed.
struct RewriteRequest: Sendable {
    let logName: String
    let temperature: Double
    let action: RewriteAction?
    let customInstruction: String?

    static func preset(_ action: RewriteAction) -> RewriteRequest {
        RewriteRequest(logName: action.logName, temperature: action.temperature, action: action, customInstruction: nil)
    }

    static func custom(_ instruction: String) -> RewriteRequest {
        RewriteRequest(logName: "Custom", temperature: 0.6, action: nil, customInstruction: instruction)
    }

    func instruction(for text: String) -> String {
        if let action { return action.instruction(for: text) }
        let request = (customInstruction ?? "").replacingOccurrences(of: "\"", with: "'")
        return "Rewrite the text so that it follows this instruction from the writer: \(request). Fix any mistakes. Keep every fact, name and number."
    }
}
