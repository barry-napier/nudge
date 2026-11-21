import Foundation

/// Testing aids that must never be active in a public build.
enum TestingFlags {
    /// Writes rewrite text to the local debug log. Debug builds only.
    static var logText: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: AppState.logTextKey)
        #else
        false
        #endif
    }
}
