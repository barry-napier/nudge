import SwiftUI

@main
struct NudgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Nudge", systemImage: "sparkle") {
            MenuContent(state: appDelegate.state, app: appDelegate)
        }
        .menuBarExtraStyle(.menu)
    }
}
