import Observation

/// State shown in the menu bar menu and the permission window.
@MainActor
@Observable
final class AppState {
    var isTrusted = false
    var isPaused = false
}
