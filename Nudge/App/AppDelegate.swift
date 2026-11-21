import AppKit
import Sparkle
import SwiftUI

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
    private var learningWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var offListWindow: NSWindow?

    /// Sparkle checks GitHub for new versions. Off in debug builds, which
    /// are not signed for release.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: AppDelegate.isReleaseBuild, updaterDelegate: nil, userDriverDelegate: nil)

    private static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    private static let welcomeDoneKey = "welcomeDone"
    private static let welcomeStepKey = "welcomeStep"
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
        selfTest?.onOffListChanged = { [weak self] in self?.offListChanged() }
        #endif
        controller.outcomes.onOutcome = { outcome in
            OutcomeStore.shared.insert(outcome)
            Learner.considerRunning()
        }
        tracker.isOff = { bundleID, site in
            ProfileStore.shared.profile.isOff(bundleID: bundleID, site: site)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        noteCurrentApp(NSWorkspace.shared.frontmostApplication)
        tracker.onChange = { [weak self] field in
            if let field { self?.state.currentSite = field.site }
            self?.controller.fieldChanged(field)
        }

        state.isTrusted = Permissions.isAccessibilityTrusted
        Log.shared.add("Accessibility: \(state.isTrusted ? "on" : "not on")")
        // People who set Nudge up before the walk-through existed skip it.
        if ProfileStore.shared.profile.hasCompletedOnboarding {
            UserDefaults.standard.set(true, forKey: Self.welcomeDoneKey)
        }
        if state.isTrusted {
            startTracking()
        }
        if !UserDefaults.standard.bool(forKey: Self.welcomeDoneKey) {
            showWelcome()
        } else if !state.isTrusted {
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

    // MARK: - Where Nudge is off

    @objc private func appActivated(_ note: Notification) {
        noteCurrentApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func noteCurrentApp(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        if state.currentApp?.bundleID != id { state.currentSite = nil }
        state.currentApp = (id, app.localizedName ?? id)
    }

    func setOff(_ off: Bool, app: (bundleID: String, name: String)) {
        ProfileStore.shared.profile.offApps[app.bundleID] = off ? app.name : nil
        Log.shared.add("Nudge turned \(off ? "off" : "on") in \(app.name)")
        offListChanged()
    }

    func setOff(_ off: Bool, site: String) {
        var sites = ProfileStore.shared.profile.offSites
        sites.removeAll { $0 == site }
        if off { sites.append(site) }
        ProfileStore.shared.profile.offSites = sites
        Log.shared.add("Nudge turned \(off ? "off" : "on") on \(site)")
        offListChanged()
    }

    /// Applies a change to the off list straight away.
    func offListChanged() {
        controller.fieldChanged(nil)
        tracker.refresh()
    }

    func showOffList() {
        if offListWindow == nil {
            offListWindow = Windows.make(
                title: "Where Nudge Is Off", size: NSSize(width: 460, height: 440),
                content: OffListView(store: ProfileStore.shared) { [weak self] in self?.offListChanged() })
        }
        Windows.present(offListWindow!)
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

    var canCheckForUpdates: Bool { Self.isReleaseBuild }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    #if DEBUG
    /// Testing aid: replays the first-run walk-through from the start.
    func showWelcomeAgain() {
        UserDefaults.standard.set(WelcomeView.Step.hello.rawValue, forKey: Self.welcomeStepKey)
        showWelcome()
    }
    #endif

    private func showWelcome() {
        let stepBinding = Binding<WelcomeView.Step>(
            get: { WelcomeView.Step(rawValue: UserDefaults.standard.integer(forKey: Self.welcomeStepKey)) ?? .hello },
            set: { [weak self] step in
                UserDefaults.standard.set(step.rawValue, forKey: Self.welcomeStepKey)
                self?.refreshWelcome()
            })
        let view = WelcomeView(
            state: state, step: stepBinding,
            openAccessibilitySettings: {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            },
            finish: { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.welcomeDoneKey)
                ProfileStore.shared.profile.hasCompletedOnboarding = true
                Log.shared.add("Welcome finished")
                self?.welcomeWindow?.close()
            })
        if welcomeWindow == nil {
            welcomeWindow = Windows.make(title: "Welcome to Nudge", size: NSSize(width: 520, height: 420), content: view)
        } else {
            welcomeWindow?.contentView = NSHostingView(rootView: view)
        }
        Windows.present(welcomeWindow!)
    }

    /// Rebuilds the welcome window after a step change, so it resizes to fit.
    private func refreshWelcome() {
        guard welcomeWindow?.isVisible == true else { return }
        Task { @MainActor in self.showWelcome() }
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
            // The walk-through continues after the restart, at the next step.
            if !UserDefaults.standard.bool(forKey: Self.welcomeDoneKey) {
                UserDefaults.standard.set(WelcomeView.Step.intelligence.rawValue, forKey: Self.welcomeStepKey)
            }
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
