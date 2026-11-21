import Foundation
import Observation

/// State shown in the menu bar menu and the permission window.
@MainActor
@Observable
final class AppState {
    var isTrusted = false
    var isPaused = false
    /// False when macOS would not let Nudge watch the keyboard.
    var keyboardReady = true

    var trigger: TriggerKey = TriggerKey(
        rawValue: UserDefaults.standard.string(forKey: "triggerKey") ?? "") ?? .rightOption
    {
        didSet { UserDefaults.standard.set(trigger.rawValue, forKey: "triggerKey") }
    }
}
