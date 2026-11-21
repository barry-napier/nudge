import SwiftUI

/// The menu shown when the user clicks the Nudge menu bar icon.
struct MenuContent: View {
    let state: AppState
    let app: AppDelegate

    var body: some View {
        if !state.isTrusted {
            Text("🔴 Accessibility: not on")
            Button("Grant Accessibility…") { app.showPermissionWindow() }
        } else if state.isPaused {
            Text("⏸️ Paused")
        } else {
            Text("🟢 Accessibility: on")
        }
        Divider()
        Button(state.isPaused ? "Resume" : "Pause") { app.togglePause() }
            .disabled(!state.isTrusted)
        Button("Show Debug Log") { app.showDebugLog() }
        Divider()
        Button("Quit Nudge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
