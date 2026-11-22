import SwiftUI

/// The first-run walk-through: what Nudge is, the one permission it needs,
/// Apple Intelligence, three questions, and how to use it.
/// Nudge restarts itself when Accessibility is turned on, so the current
/// step is saved and the walk-through picks up where it left off.
struct WelcomeView: View {
    enum Step: Int {
        case hello, accessibility, intelligence, profile, tryIt
    }

    let state: AppState
    @Binding var step: Step
    let openAccessibilitySettings: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepDots(current: step.rawValue, total: 5)
                .padding(.bottom, 18)
            Group {
                switch step {
                case .hello: hello
                case .accessibility: accessibility
                case .intelligence: intelligence
                case .profile:
                    OnboardingView(store: ProfileStore.shared) { step = .tryIt }
                        .padding(-24)  // OnboardingView brings its own padding
                case .tryIt: tryIt
                }
            }
        }
        .padding(28)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hello: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text("Welcome to Nudge").font(.largeTitle.bold())
            }
            Text("Nudge fixes and rewrites your writing in any app, with Apple's AI on your Mac.")
                .font(.title3)
            Label("Nudge never sends your writing anywhere. There is no account and no server.", systemImage: "lock")
            Label("It's open source, so anyone can check that.", systemImage: "chevron.left.forwardslash.chevron.right")
            Spacer(minLength: 6)
            HStack {
                Spacer()
                Button("Get Started") { step = .accessibility }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One permission").font(.title.bold())
            Text("Nudge needs Accessibility access. It uses it to see which text box you are typing in, to read the text you ask it to rewrite, to put the new text back, and to notice the double-tap of the Option key.")
            Text("Nudge checks the box you click into to see if it holds text. It reads that text to rewrite it and, while learning is on, for up to 90 seconds after. It skips password fields, and you can turn learning off.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            Text(state.isTrusted ? "🟢 Accessibility is on" : "🔴 Accessibility is not on yet")
                .font(.headline)
            if state.isTrusted {
                HStack {
                    Spacer()
                    Button("Continue") { step = .intelligence }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Open System Settings", action: openAccessibilitySettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("Switch Nudge on in the list. Nudge then restarts itself and comes back here.")
                    .font(.callout)
                Text("Nudge already on, but this still says not on? Select Nudge in the list, remove it with the minus button, then click Open System Settings again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var intelligence: some View {
        let problem = Rewriter.unavailableMessage
        return VStack(alignment: .leading, spacing: 14) {
            Text("Apple Intelligence").font(.title.bold())
            if let problem {
                Text("🔴 \(problem)").font(.headline)
                Text("Nudge uses Apple's AI model on this Mac. Without it, Nudge can show its icon but cannot rewrite text.")
                Button("Open Apple Intelligence Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Text("🟢 Apple Intelligence is ready.").font(.headline)
                Text("Nudge runs Apple's model right here on your Mac. Rewrites take a second or two.")
            }
            HStack {
                Spacer()
                Button(problem == nil ? "Continue" : "Continue Anyway") { step = .profile }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try it").font(.title.bold())
            VStack(alignment: .leading, spacing: 10) {
                Label("Click into any text box. A small ✦ appears in its corner.", systemImage: "1.circle")
                Label("Tap the right Option key twice, fast. Or click the ✦.", systemImage: "2.circle")
                Label("Pick an action with the arrow keys and Return, or press 1 to 8.", systemImage: "3.circle")
                Label("Don't like it? Open the menu again and choose Undo.", systemImage: "4.circle")
            }
            Text("Everything else is in the ✦ menu in your menu bar.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: finish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct StepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
    }
}
