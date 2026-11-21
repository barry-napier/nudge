import AppKit
import SwiftUI

/// Everything Nudge has learned, with controls to keep, dismiss, delete,
/// pause and reset. Nothing here ever leaves the Mac.
struct LearningView: View {
    @Bindable var store: ProfileStore

    @State private var counts: [Outcome.Kind: Int] = [:]
    @State private var waiting = 0
    @State private var recent: [Outcome] = []
    @State private var isLearning = false
    @State private var lastRunNote: String?

    private var rules: [LearnedRule] { store.profile.learnedRules }

    var body: some View {
        Form {
            Section {
                Toggle("Learn from what I keep, edit and undo", isOn: $store.profile.learningEnabled)
            } footer: {
                Text("After each rewrite, Nudge watches that one field for up to 90 seconds to see what you do with it. It saves short snippets on this Mac only, and never sends them anywhere.")
            }

            Section("Suggestions") {
                let proposed = rules.filter { $0.status == .proposed }
                if proposed.isEmpty {
                    Text("No suggestions right now.").foregroundStyle(.secondary)
                }
                ForEach(proposed) { rule in
                    HStack {
                        RuleText(rule: rule)
                        Spacer()
                        Button("Keep") { keep(rule) }
                            .buttonStyle(.borderedProminent)
                        Button("Dismiss") { set(rule, to: .dismissed) }
                    }
                }
            }

            Section {
                let active = rules.filter { $0.status == .active }
                if active.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(active) { rule in
                    HStack {
                        RuleText(rule: rule)
                        Spacer()
                        Button {
                            store.profile.learnedRules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this rule")
                    }
                }
            } header: {
                Text("Rules in use")
            } footer: {
                Text("These are added to your profile for every rewrite. If space runs short, the weakest go first.")
            }

            Section {
                LabeledContent("Rewrites recorded") {
                    Text(summaryOfCounts)
                }
                LabeledContent("Next learning pass") {
                    Text(waiting >= Learner.outcomesPerPass ? "Soon" : "After \(Learner.outcomesPerPass - waiting) more rewrites, or weekly")
                }
                HStack {
                    Button(isLearning ? "Learning…" : "Learn Now", action: learnNow)
                        .disabled(isLearning || total == 0)
                    if let lastRunNote {
                        Text(lastRunNote).foregroundStyle(.secondary)
                    }
                }
                if !recent.isEmpty {
                    DisclosureGroup("Last \(recent.count) outcomes") {
                        ForEach(recent) { o in
                            HStack {
                                Text(o.kind.rawValue.capitalized + (o.rerunTo.map { " as \($0)" } ?? ""))
                                    .frame(width: 130, alignment: .leading)
                                Text(o.action).frame(width: 70, alignment: .leading)
                                Text(o.appName).foregroundStyle(.secondary)
                                Spacer()
                                Text(o.created, style: .relative).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            } header: {
                Text("Progress")
            }

            Section {
                if store.profile.learningExcluded.isEmpty {
                    Text("Nudge learns from every app.").foregroundStyle(.secondary)
                }
                ForEach(store.profile.learningExcluded.sorted { $0.value < $1.value }, id: \.key) { id, name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button {
                            store.profile.learningExcluded[id] = nil
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Add App") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") { exclude(app) }
                    }
                }
                .fixedSize()
            } header: {
                Text("Never learn from")
            } footer: {
                Text("Adding an app also deletes what Nudge recorded there.")
            }

            Section {
                Button("Forget Everything Learned…", role: .destructive, action: reset)
            } footer: {
                Text("Deletes every recorded rewrite and every learned rule. The rest of your profile stays.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .onAppear(perform: refresh)
    }

    private var total: Int { counts.values.reduce(0, +) }

    private var summaryOfCounts: String {
        let parts = Outcome.Kind.allCases.compactMap { kind -> String? in
            guard let n = counts[kind], n > 0 else { return nil }
            return "\(n) \(kind == .rerun ? "tried again" : kind.rawValue)"
        }
        return parts.isEmpty ? "None yet" : parts.joined(separator: ", ")
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { store.profile.learningExcluded[$0.bundleIdentifier ?? ""] == nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func refresh() {
        counts = OutcomeStore.shared.countsByKind()
        waiting = OutcomeStore.shared.count(unprocessedOnly: true)
        recent = OutcomeStore.shared.recent(limit: 10)
    }

    private func set(_ rule: LearnedRule, to status: LearnedRule.Status) {
        guard let index = store.profile.learnedRules.firstIndex(where: { $0.id == rule.id }) else { return }
        store.profile.learnedRules[index].status = status
        Log.shared.add("Learning | \(status == .active ? "kept" : "dismissed"): \(rule.text)")
    }

    private func keep(_ rule: LearnedRule) {
        set(rule, to: .active)
        // A voice suggestion sets the app's voice straight away.
        if let tone = rule.suggestedTone, let bundleID = rule.bundleID {
            if let index = store.profile.voices.firstIndex(where: { $0.kind == .app && $0.key == bundleID }) {
                store.profile.voices[index].tone = tone
            } else {
                store.profile.voices.append(Voice(kind: .app, key: bundleID, name: rule.appName ?? bundleID, tone: tone))
            }
        }
    }

    private func exclude(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        store.profile.learningExcluded[id] = app.localizedName ?? id
        OutcomeStore.shared.delete(bundleID: id)
        refresh()
    }

    private func learnNow() {
        isLearning = true
        Task {
            let added = await Learner.run()
            lastRunNote = added == 0 ? "No new patterns yet." : "\(added) new suggestion\(added == 1 ? "" : "s")."
            isLearning = false
            refresh()
        }
    }

    private func reset() {
        let alert = NSAlert()
        alert.messageText = "Forget everything Nudge learned?"
        alert.informativeText = "This deletes every recorded rewrite and every learned rule. It cannot be undone."
        alert.addButton(withTitle: "Forget Everything")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        OutcomeStore.shared.deleteAll()
        store.profile.learnedRules.removeAll()
        store.profile.lastLearnedAt = nil
        Log.shared.add("Learning | everything forgotten")
        refresh()
    }
}

private struct RuleText: View {
    let rule: LearnedRule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.text)
            Text("\(rule.scopeTitle) · seen \(rule.evidence) time\(rule.evidence == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
