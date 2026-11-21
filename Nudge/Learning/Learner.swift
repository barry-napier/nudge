import Foundation
import FoundationModels

/// Turns outcomes into suggested rules for the writer profile.
///
/// Two sources:
/// - Counted patterns, with no model involved, for example exclamation marks
///   removed in several edits, or a different tone chosen in one app.
/// - Apple's on-device model, which reads recent edits and undos and writes a
///   few short rules. It sometimes invents rules, so it only runs when there
///   are enough edits and undos, and the writer confirms every rule.
@MainActor
enum Learner {
    /// Learn after this many new outcomes, as the plan says.
    static let outcomesPerPass = 20
    /// Or once a week, if at least this many came in.
    static let weeklyMinimum = 5
    /// The model only runs with at least this many edits and undos.
    static let modelMinimum = 5

    private(set) static var isRunning = false

    /// Called after each outcome. Starts a pass when enough are waiting.
    static func considerRunning() {
        let waiting = OutcomeStore.shared.count(unprocessedOnly: true)
        let lastRun = ProfileStore.shared.profile.lastLearnedAt ?? .distantPast
        let weekly = Date().timeIntervalSince(lastRun) > 7 * 24 * 3600 && waiting >= weeklyMinimum
        if waiting >= outcomesPerPass || weekly {
            Task { await run() }
        }
    }

    /// Returns how many new suggestions it added.
    @discardableResult
    static func run() async -> Int {
        guard !isRunning else { return 0 }
        isRunning = true
        defer { isRunning = false }

        let outcomes = OutcomeStore.shared.recent(limit: 120)
        guard !outcomes.isEmpty else { return 0 }
        Log.shared.add("Learning | looking at \(outcomes.count) outcomes")

        var proposals = countedPatterns(outcomes, appName: nil)
        for (bundleID, appOutcomes) in Dictionary(grouping: outcomes, by: \.bundleID) where appOutcomes.count >= 8 {
            proposals += countedPatterns(appOutcomes, appName: appOutcomes[0].appName).map { rule in
                var rule = rule
                rule.bundleID = bundleID
                return rule
            }
        }
        proposals += voicePatterns(outcomes)
        proposals += await modelRules(outcomes)

        var store = ProfileStore.shared.profile
        var added = 0
        for proposal in proposals where !store.learnedRules.contains(where: { isSameRule($0, proposal) }) {
            store.learnedRules.append(proposal)
            added += 1
            Log.shared.add("Learning | suggested: \(proposal.text) (\(proposal.scopeTitle), evidence \(proposal.evidence))")
        }
        store.lastLearnedAt = Date()
        ProfileStore.shared.profile = store
        OutcomeStore.shared.markAllProcessed()
        Log.shared.add("Learning | done, \(added) new suggestion\(added == 1 ? "" : "s")")
        return added
    }

    // MARK: - Counted patterns

    private static func countedPatterns(_ outcomes: [Outcome], appName: String?) -> [LearnedRule] {
        let edits = outcomes.compactMap { o -> (String, String)? in
            guard o.kind == .edited, let final = o.final else { return nil }
            return (o.rewrite, final)
        }
        guard edits.count >= 3 else { return [] }
        var rules: [LearnedRule] = []

        let fewerExclamations = edits.filter { count("!", in: $0.1) < count("!", in: $0.0) }.count
        let moreExclamations = edits.filter { count("!", in: $0.1) > count("!", in: $0.0) }.count
        if fewerExclamations >= 3, moreExclamations == 0 {
            rules.append(LearnedRule(text: "Avoid exclamation marks", appName: appName, evidence: fewerExclamations))
        }

        let shorter = edits.filter { words($0.1) < Int(Double(words($0.0)) * 0.8) }.count
        if shorter >= 3, Double(shorter) / Double(edits.count) >= 0.6 {
            rules.append(LearnedRule(text: "Keep it shorter and tighter", appName: appName, evidence: shorter))
        }

        let fewerEmoji = edits.filter { emoji(in: $0.1) < emoji(in: $0.0) }.count
        if fewerEmoji >= 2, edits.allSatisfy({ emoji(in: $0.1) <= emoji(in: $0.0) }) {
            rules.append(LearnedRule(text: "Do not add emoji", appName: appName, evidence: fewerEmoji))
        }
        return rules
    }

    /// The writer keeps switching to a different tone in one app.
    private static func voicePatterns(_ outcomes: [Outcome]) -> [LearnedRule] {
        let tones: [String: Tone] = ["Formal": .formal, "Casual": .casual, "Friendly": .friendly, "Direct": .direct]
        let switches = outcomes.compactMap { o -> (String, String, Tone)? in
            guard o.kind == .rerun, let to = o.rerunTo, let tone = tones[to] else { return nil }
            return (o.bundleID, o.appName, tone)
        }
        var rules: [LearnedRule] = []
        for (key, group) in Dictionary(grouping: switches, by: { "\($0.0)|\($0.2.rawValue)" }) where group.count >= 2 {
            let (bundleID, appName, tone) = group[0]
            _ = key
            rules.append(LearnedRule(
                text: "Use a \(tone.title.lowercased()) tone in \(appName)", bundleID: bundleID, appName: appName,
                evidence: group.count, suggestedTone: tone))
        }
        return rules
    }

    // MARK: - Model rules

    @Generable
    struct StyleRules {
        @Guide(
            description: "Instructions for future rewrites, so they match this writer. Each one is under 10 words and starts with a verb, for example 'Write numbers as digits' or 'Open with the main request'. Each must be about the wording or style of the text, and at least two examples must support it.",
            .maximumCount(4))
        var rules: [String]
    }

    private static func modelRules(_ outcomes: [Outcome]) async -> [LearnedRule] {
        let signals = outcomes.filter { $0.kind == .edited || $0.kind == .undone }
        guard signals.count >= modelMinimum, SystemLanguageModel.default.availability == .available else {
            Log.shared.add("Learning | model skipped: needs \(modelMinimum) edits or undos, has \(signals.count)")
            return []
        }
        let kept = outcomes.filter { $0.kind == .accepted }.prefix(4)
        var lines: [String] = []
        for (index, o) in (Array(signals.prefix(12)) + kept).enumerated() {
            let wrote = short(o.rewrite)
            switch o.kind {
            case .edited:
                lines.append("\(index + 1). Edited. Nudge wrote: \"\(wrote)\" The writer changed it to: \"\(short(o.final ?? ""))\"")
            case .undone:
                lines.append("\(index + 1). Undone. Nudge wrote: \"\(wrote)\" The writer went back to: \"\(short(o.original))\"")
            default:
                lines.append("\(index + 1). Kept as is. Nudge wrote: \"\(wrote)\"")
            }
        }
        let prompt = """
            Here are recent rewrites and what the writer did with them.

            \(lines.joined(separator: "\n"))

            Write up to 4 instructions that would make future rewrites match this writer. \
            If the examples show no clear pattern, return none.
            """
        let session = LanguageModelSession(instructions: """
            You study how one writer edits the suggestions of a writing assistant. \
            You find patterns in what they keep, change and undo. You describe their style as short rules. \
            Never quote or repeat the content of the examples.
            """)
        do {
            let response = try await session.respond(
                to: prompt, generating: StyleRules.self, options: GenerationOptions(temperature: 0.3))
            return response.content.rules
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
                .filter { !$0.isEmpty && $0.split(separator: " ").count <= 12 }
                .map { LearnedRule(text: $0, evidence: 2) }
        } catch {
            Log.shared.add("Learning | model failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Helpers

    /// Rules with mostly the same words count as the same rule, so a rule the
    /// writer dismissed is never suggested again in other words.
    static func isSameRule(_ a: LearnedRule, _ b: LearnedRule) -> Bool {
        guard a.bundleID == b.bundleID else { return false }
        if a.suggestedTone != nil || b.suggestedTone != nil { return a.suggestedTone == b.suggestedTone }
        let x = keyWords(a.text)
        let y = keyWords(b.text)
        guard !x.isEmpty, !y.isEmpty else { return a.text.lowercased() == b.text.lowercased() }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.6
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "use", "keep", "avoid", "your", "their", "more", "less", "them", "into",
    ]

    private static func keyWords(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) })
    }

    private static func count(_ character: Character, in text: String) -> Int {
        text.filter { $0 == character }.count
    }

    private static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func emoji(in text: String) -> Int {
        text.unicodeScalars.filter { $0.properties.isEmojiPresentation }.count
    }

    private static func short(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
    }
}
