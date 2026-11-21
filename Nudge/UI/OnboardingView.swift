import SwiftUI

/// Three quick questions, so the profile is useful in under a minute.
struct OnboardingView: View {
    @Bindable var store: ProfileStore
    let done: () -> Void

    @State private var avoidText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Make Nudge sound like you")
                .font(.title2.bold())
            Text("Three quick questions. You can change these any time from the Nudge menu, under Writer Profile.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Who are you?").font(.headline)
                HStack {
                    TextField("Name", text: $store.profile.name, prompt: Text("Your name"))
                    TextField("Role", text: $store.profile.role, prompt: Text("Your role, like software founder"))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("2. How do you usually write?").font(.headline)
                Picker("Usual tone", selection: $store.profile.tone) {
                    ForEach(Tone.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("3. Any words Nudge should never use?").font(.headline)
                TextField("Never use", text: $avoidText, prompt: Text("synergy, circle back, just"))
                Text("Separate words with commas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Your answers stay on this Mac. Nothing is sent.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Skip") { finish(saveWords: false) }
                Spacer()
                Button("Save") { finish(saveWords: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { avoidText = store.profile.avoidWords.joined(separator: ", ") }
    }

    private func finish(saveWords: Bool) {
        if saveWords {
            store.profile.avoidWords = avoidText.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        store.profile.hasCompletedOnboarding = true
        done()
    }
}
