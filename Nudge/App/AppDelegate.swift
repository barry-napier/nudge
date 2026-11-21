import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    private let tracker = FocusTracker()
    private let controller = RewriteController()
    private var isTracking = false
    private var trustTimer: Timer?
    private var permissionWindow: NSWindow?
    private var logWindow: NSWindow?
    private var profileWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var learningWindow: NSWindow?
    #if DEBUG
    private var selfTest: SelfTest?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let path = Bundle.main.bundlePath
        Log.shared.add("Nudge \(version) launched from \(path)")
        if path != "/Applications/Nudge.app" {
            Log.shared.add("Warning: not running from /Applications. Use scripts/build.sh so permissions stick.")
        }

        #if DEBUG
        selfTest = SelfTest(controller: controller)
        #endif
        controller.outcomes.onOutcome = { outcome in
            OutcomeStore.shared.insert(outcome)
            Learner.considerRunning()
        }
        tracker.onChange = { [weak self] field in
            self?.controller.fieldChanged(field)
        }

        state.isTrusted = Permissions.isAccessibilityTrusted
        Log.shared.add("Accessibility: \(state.isTrusted ? "on" : "not on")")
        if state.isTrusted {
            startTracking()
            showOnboardingIfNeeded()
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

    func triggerChanged() {
        controller.keys.trigger = state.trigger
        Log.shared.add("Double-tap key set to \(state.trigger.title)")
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

    func showProfileWindow() {
        if profileWindow == nil {
            profileWindow = Windows.make(
                title: "Writer Profile", size: NSSize(width: 560, height: 720),
                content: ProfileView(store: ProfileStore.shared))
        }
        Windows.present(profileWindow!)
    }

    func showLearningWindow() {
        if learningWindow == nil {
            learningWindow = Windows.make(
                title: "What Nudge Learned", size: NSSize(width: 560, height: 640),
                content: LearningView(store: ProfileStore.shared))
        }
        Windows.present(learningWindow!)
    }

    private func showOnboardingIfNeeded() {
        guard !ProfileStore.shared.profile.hasCompletedOnboarding else { return }
        if onboardingWindow == nil {
            let view = OnboardingView(store: ProfileStore.shared) { [weak self] in
                self?.onboardingWindow?.close()
                Log.shared.add("Writer profile set up")
            }
            onboardingWindow = Windows.make(
                title: "Welcome to Nudge", size: NSSize(width: 480, height: 420), content: view)
        }
        Windows.present(onboardingWindow!)
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
        controller.keys.trigger = state.trigger
        state.keyboardReady = controller.keys.start()
        if state.keyboardReady {
            Log.shared.add("Watching for a double-tap of \(state.trigger.title)")
        }
    }

    private func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        tracker.stop()
        controller.keys.stop()
        controller.outcomes.stop()
        controller.fieldChanged(nil)
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
