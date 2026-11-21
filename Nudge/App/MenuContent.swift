import SwiftUI

/// The menu shown when the user clicks the Nudge menu bar icon.
struct MenuContent: View {
    @Bindable var state: AppState
    let app: AppDelegate
    private let profile = ProfileStore.shared

    var body: some View {
        if !state.isTrusted {
            Text("🔴 Accessibility: not on")
            Button("Grant Accessibility…") { app.showPermissionWindow() }
        } else if state.isPaused {
            Text("⏸️ Paused")
        } else {
            Text("🟢 Accessibility: on")
            if state.logText {
                Text("📝 Logging text for testing")
            }
            if !state.keyboardReady {
                Text("⚠️ Double-tap is not working. See Debug Log.")
            }
        }
        Divider()
        Picker("Double-tap Key", selection: $state.trigger) {
            ForEach(TriggerKey.allCases) { key in
                Text(key.title).tag(key)
            }
        }
        .onChange(of: state.trigger) { app.triggerChanged() }
        Button(state.isPaused ? "Resume" : "Pause") { app.togglePause() }
            .disabled(!state.isTrusted)
        let suggestions = profile.profile.learnedRules.filter { $0.status == .proposed }.count
        if suggestions > 0 {
            Button("💡 \(suggestions) suggestion\(suggestions == 1 ? "" : "s") to review…") { app.showLearningWindow() }
        }
        Button("Writer Profile…") { app.showProfileWindow() }
        Button("What Nudge Learned…") { app.showLearningWindow() }
        Toggle("Log Text for Testing", isOn: $state.logText)
            .onChange(of: state.logText) {
                Log.shared.add(state.logText
                    ? "Text logging turned on. Rewrites now save their text to this log."
                    : "Text logging turned off.")
            }
        Button("Show Debug Log") { app.showDebugLog() }
        Divider()
        Button("Quit Nudge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
