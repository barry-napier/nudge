import Foundation
import Observation

/// State shown in the menu bar menu and the permission window.
@MainActor
@Observable
final class AppState {
    var isTrusted = false
    var isPaused = false
    /// The app the writer is in, for the menu's Turn Off items.
    var currentApp: (bundleID: String, name: String)?
    /// The website of the focused field, if it is in a web page.
    var currentSite: String?

    /// False when macOS would not let Nudge watch the keyboard.
    var keyboardReady = true

    /// Testing aid: also write the before and after text of each rewrite to
    /// the local debug log. Off by default.
    var logText = UserDefaults.standard.bool(forKey: AppState.logTextKey) {
        didSet { UserDefaults.standard.set(logText, forKey: AppState.logTextKey) }
    }
    nonisolated static let logTextKey = "logTextForTesting"

    var trigger: TriggerKey = TriggerKey(
        rawValue: UserDefaults.standard.string(forKey: "triggerKey") ?? "") ?? .rightOption
    {
        didSet { UserDefaults.standard.set(trigger.rawValue, forKey: "triggerKey") }
    }
}
