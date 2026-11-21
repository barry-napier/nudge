import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    private let tracker = FocusTracker()
    private let icon = IconPanel()
    private var isTracking = false
    private var trustTimer: Timer?
    private var permissionWindow: NSWindow?
    private var logWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let path = Bundle.main.bundlePath
        Log.shared.add("Nudge \(version) launched from \(path)")
        if path != "/Applications/Nudge.app" {
            Log.shared.add("Warning: not running from /Applications. Use scripts/build.sh so permissions stick.")
        }

        tracker.onChange = { [weak self] field in
            guard let self else { return }
            if let field {
                self.icon.show(for: field.visibleFrame)
            } else {
                self.icon.hide()
            }
        }

        state.isTrusted = Permissions.isAccessibilityTrusted
        Log.shared.add("Accessibility: \(state.isTrusted ? "on" : "not on")")
        if state.isTrusted {
            startTracking()
        } else {
            showPermissionWindow()
        }

        // Watch for the permission being granted or removed while running.
        trustTimer = Timer.scheduledTimer(
            timeInterval: 1, target: self, selector: #selector(checkTrust),
            userInfo: nil, repeats: true)
    }

    // MARK: - Menu actions

    func togglePause() {
        state.isPaused.toggle()
        Log.shared.add(state.isPaused ? "Paused" : "Resumed")
        if state.isPaused {
            stopTracking()
        } else {
            startTracking()
        }
    }

    func showPermissionWindow() {
        if permissionWindow == nil {
            let view = PermissionView(state: state) {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }
            permissionWindow = Windows.make(
                title: "Welcome to Nudge", size: NSSize(width: 460, height: 380), content: view)
        }
        Windows.present(permissionWindow!)
    }

    func showDebugLog() {
        if logWindow == nil {
            logWindow = Windows.make(
                title: "Nudge Debug Log", size: NSSize(width: 720, height: 420),
                content: DebugLogView(log: Log.shared))
        }
        Windows.present(logWindow!)
    }

    // MARK: - Tracking

    private func startTracking() {
        guard !isTracking, state.isTrusted, !state.isPaused else { return }
        isTracking = true
        tracker.start()
    }

    private func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        tracker.stop()
        icon.hide()
    }

    @objc private func checkTrust() {
        let trusted = Permissions.isAccessibilityTrusted
        guard trusted != state.isTrusted else { return }
        state.isTrusted = trusted
        if trusted {
            // macOS often needs a fresh process before the grant fully applies.
            Log.shared.add("Accessibility turned on. Restarting Nudge.")
            relaunch()
        } else {
            Log.shared.add("Accessibility turned off. Stopped watching text fields.")
            stopTracking()
        }
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
