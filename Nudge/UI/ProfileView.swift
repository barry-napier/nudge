import AppKit
import SwiftUI

/// Edits the writer profile. Every change saves at once.
struct ProfileView: View {
    @Bindable var store: ProfileStore

    @State private var newSite = ""
    @State private var previewText = "hey, i just wanted to check if your free to chat about the color changes tomorow"
    @State private var previewAction: RewriteAction = .improve
    @State private var previewResult = ""
    @State private var isPreviewing = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $store.profile.name, prompt: Text("Barry"))
                TextField("Role", text: $store.profile.role, prompt: Text("software founder"))
            } header: {
                Text("About you")
            } footer: {
                Text("Your profile stays on this Mac. Nudge never sends it anywhere.")
            }

            Section("How you write") {
                Picker("Usual tone", selection: $store.profile.tone) {
                    ForEach(Tone.allCases) { Text($0.title).tag($0) }
                }
                Picker("How formal", selection: $store.profile.formality) {
                    ForEach(Formality.allCases) { Text($0.title).tag($0) }
                }
                Picker("Spelling", selection: $store.profile.language) {
                    ForEach(EnglishVariant.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                ListField(title: "Never use", prompt: "synergy, circle back", items: $store.profile.avoidWords)
                ListField(title: "Phrases you like", prompt: "sounds good, happy to help", items: $store.profile.preferredPhrases)
                ListField(title: "Your sign-offs", prompt: "Cheers, Thanks", items: $store.profile.signOffs)
            } header: {
                Text("Words")
            } footer: {
                Text("Separate items with commas.")
            }

            Section {
                ForEach(0..<3, id: \.self) { index in
                    SampleEditor(index: index, samples: $store.profile.samples)
                }
            } header: {
                Text("Writing samples")
            } footer: {
                Text("Paste two or three short messages you wrote. Nudge copies your voice from them, never the content. It uses the first two.")
            }

            Section {
                if store.profile.voices.isEmpty {
                    Text("No app or website voices yet. Everything uses your usual tone.")
                        .foregroundStyle(.secondary)
                }
                ForEach($store.profile.voices) { $voice in
                    HStack {
                        Image(systemName: voice.kind == .app ? "app" : "globe")
                            .foregroundStyle(.secondary)
                        Picker(voice.name, selection: $voice.tone) {
                            ForEach(Tone.allCases) { Text($0 == .none ? "Usual tone" : $0.title).tag($0) }
                        }
                        Button {
                            store.profile.voices.removeAll { $0.id == voice.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                HStack {
                    Menu("Add App") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "App") { addApp(app) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    TextField("Website", text: $newSite, prompt: Text("mail.google.com"))
                        .frame(maxWidth: 200)
                        .onSubmit(addSite)
                    Button("Add Website", action: addSite)
                        .disabled(siteHost == nil)
                }
            } header: {
                Text("Voices for apps and websites")
            } footer: {
                Text("For example casual in Slack and formal in Mail. Improve and Make concise use these. A website voice wins over its browser's app voice.")
            }

            Section {
                TextField("Sample", text: $previewText, axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    Picker("Action", selection: $previewAction) {
                        ForEach(RewriteAction.allCases) { Text($0.title).tag($0) }
                    }
                    Button(isPreviewing ? "Rewriting…" : "Preview", action: preview)
                        .disabled(isPreviewing || previewText.isEmpty)
                }
                if !previewResult.isEmpty {
                    Text(previewResult)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
                }
                DisclosureGroup("What Nudge tells the model") {
                    Text(summaryShown)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Try it")
            }

            Section {
                HStack {
                    Button("Export…") { store.exportProfile() }
                    Button("Import…") { store.importProfile() }
                    Spacer()
                    Button("Show File") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                    }
                }
            } header: {
                Text("Back up")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 600)
    }

    private var summaryShown: String {
        let tone = store.profile.voice(bundleID: nil, site: nil)?.tone
        let summary = store.profile.summary(for: previewAction, tone: tone) ?? "(nothing)"
        let words = summary.split(whereSeparator: \.isWhitespace).count
        return summary + "\n\n\(words) words. The limit is \(WriterProfile.summaryWordLimit)."
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { app in !store.profile.voices.contains { $0.key == app.bundleIdentifier } }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func addApp(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        store.profile.voices.append(Voice(kind: .app, key: id, name: app.localizedName ?? id, tone: .casual))
    }

    /// "https://mail.google.com/x" or "mail.google.com" both become "mail.google.com".
    private var siteHost: String? {
        let text = newSite.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let host = URL(string: withScheme)?.host(), host.contains(".") else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func addSite() {
        guard let host = siteHost, !store.profile.voices.contains(where: { $0.key == host }) else { return }
        store.profile.voices.append(Voice(kind: .site, key: host, name: host, tone: .formal))
        newSite = ""
    }

    private func preview() {
        isPreviewing = true
        let profile = store.profile
        var request = RewriteRequest.preset(previewAction)
        request.profileSummary = profile.summary(for: previewAction, tone: profile.voice(bundleID: nil, site: nil)?.tone)
        request.avoidWords = WriterProfile.clean(profile.avoidWords)
        request.signOffWords = profile.signOffWords
        let text = previewText
        Task {
            do {
                previewResult = try await Rewriter.rewrite(text, request: request)
            } catch {
                previewResult = error.localizedDescription
            }
            isPreviewing = false
        }
    }
}

/// A comma-separated list edited as one line of text.
private struct ListField: View {
    let title: String
    let prompt: String
    @Binding var items: [String]
    @State private var text = ""

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .onAppear { text = items.joined(separator: ", ") }
            .onChange(of: text) {
                items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
    }
}

private struct SampleEditor: View {
    let index: Int
    @Binding var samples: [String]

    var body: some View {
        TextField("Sample \(index + 1)", text: binding, prompt: Text("A short message you wrote"), axis: .vertical)
            .lineLimit(2...5)
    }

    private var binding: Binding<String> {
        Binding(
            get: { index < samples.count ? samples[index] : "" },
            set: { value in
                while samples.count <= index { samples.append("") }
                samples[index] = value
                while let last = samples.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    samples.removeLast()
                }
            })
    }
}
