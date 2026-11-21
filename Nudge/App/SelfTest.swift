#if DEBUG
import AppKit
import ApplicationServices

/// A self-test for development builds only. It drives TextEdit with Nudge's
/// own Accessibility permission, so tests can run without anyone at the Mac.
///
/// Start it from Terminal:
///     scripts/selftest.sh
/// Results go to the debug log as lines starting with "SELFTEST".
/// It cleans up after itself: test outcomes and test rules are removed.
@MainActor
final class SelfTest {
    static let notification = Notification.Name("com.barrynapier.nudge.selftest")

    private let controller: RewriteController
    private var isRunning = false
    private var failures = 0
    /// The test's own document. The test never writes anywhere else.
    private let fileURL = FileManager.default.temporaryDirectory.appending(path: "nudge-selftest.txt")

    init(controller: RewriteController) {
        self.controller = controller
        DistributedNotificationCenter.default().addObserver(
            forName: Self.notification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        failures = 0
        Task {
            await run()
            isRunning = false
        }
    }

    private static let sentence = "hey sam!! just wanted to check if you could send the report by friday!! thanks so much!!"

    private func run() async {
        log("start")
        let firstID = OutcomeStore.shared.latestID()
        let savedProfile = ProfileStore.shared.profile
        // Always clean up, even if the test stops early.
        defer {
            OutcomeStore.shared.delete(after: firstID)
            ProfileStore.shared.profile = savedProfile
        }

        guard let element = await openTextEdit() else {
            log("FAIL could not focus the test's own TextEdit document. Nothing was changed.")
            return
        }

        // 1. Keep: rewrite, then leave the app.
        guard await rewrite(in: element) else { return abort() }
        await leaveAndReturn()
        await expectLatestOutcome(.accepted, "keep")

        // 2. Edit: rewrite, change the words, then leave.
        guard await rewrite(in: element) else { return abort() }
        guard let value = AX.string(element, kAXValueAttribute) else { return abort() }
        let edited = value.replacingOccurrences(of: "Sam", with: "Samuel") + " Cheers."
        guard safelySet(element, edited) else { return abort() }
        try? await Task.sleep(for: .seconds(1.5))  // let the watcher see the edit
        await leaveAndReturn()
        await expectLatestOutcome(.edited, "edit")

        // 3. Undo: rewrite, then Nudge's Undo.
        guard await rewrite(in: element) else { return abort() }
        guard isTestDocument(element), controller.testUndo(on: element) else { return abort() }
        await waitUntil(seconds: 10) { !self.controller.testIsBusy }
        let restored = AX.string(element, kAXValueAttribute) ?? ""
        check(TextAccess.looselyEqual(restored, Self.sentence), "undo restores the original text")
        await expectLatestOutcome(.undone, "undo")

        // 4. Learning pass on made-up edits that drop exclamation marks.
        let beforeLearning = OutcomeStore.shared.latestID()
        for index in 0..<6 {
            OutcomeStore.shared.insert(Outcome(
                bundleID: "selftest", appName: "Self-test", action: "Improve", kind: .edited,
                original: "draft \(index)", rewrite: "Great news! We shipped version \(index)!",
                final: "We shipped version \(index)."))
        }
        _ = beforeLearning
        _ = await Learner.run()
        let suggested = ProfileStore.shared.profile.learnedRules.filter { $0.status == .proposed }.map(\.text)
        log("learning suggested: \(suggested)")
        check(suggested.contains("Avoid exclamation marks"), "learning suggests 'Avoid exclamation marks'")

        closeTextEditDocument(element)
        log(failures == 0 ? "PASS all checks" : "FAIL \(failures) check(s) failed")
    }

    // MARK: - Steps

    /// Stops the test without touching anything else, and cleans up records.
    private func abort() {
        log("FAIL stopped early: the focused field is not the test's own document. Nothing else was changed.")
    }

    /// Writes to `element` only if it is the test document and has focus right now.
    private func safelySet(_ element: AXUIElement, _ text: String) -> Bool {
        guard isTestDocument(element), isFocused(element) else { return false }
        return AX.setString(element, kAXValueAttribute, text) == .success
    }

    /// True if TextEdit's focused element is `element`, read fresh from TextEdit.
    private func isFocused(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return AX.focusedElement(pid: pid) == element
    }

    /// True only for a text area inside the test's own TextEdit document window.
    private func isTestDocument(_ element: AXUIElement?) -> Bool {
        guard let element, let window = AX.element(element, kAXWindowAttribute),
              let document = AX.string(window, kAXDocumentAttribute),
              let url = URL(string: document) else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
            == fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Opens the test's own plain text file in TextEdit and waits until Nudge
    /// is focused on it. Any other TextEdit window is left alone.
    private func openTextEdit() async -> AXUIElement? {
        let url = fileURL
        try? Self.sentence.write(to: url, atomically: true, encoding: .utf8)
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            return nil
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: config)
        await waitUntil(seconds: 8) { self.isTestDocument(self.controller.testField?.element) }
        let element = controller.testField?.element
        return isTestDocument(element) ? element : nil
    }

    /// Puts the test sentence in the field and runs Improve on all of it.
    /// Returns false, and changes nothing, unless both the element and the
    /// field Nudge will rewrite are the test's own document.
    private func rewrite(in element: AXUIElement) async -> Bool {
        guard safelySet(element, Self.sentence) else { return false }
        AX.setRange(element, kAXSelectedTextRangeAttribute,
                    CFRange(location: TextAccess.utf16Length(Self.sentence), length: 0))
        try? await Task.sleep(for: .milliseconds(300))
        // Checked again here, in the same step as the run, because focus may
        // have moved during the pause (for example to a dialog).
        guard isTestDocument(element), controller.testRun(.preset(.improve), on: element) else { return false }
        await waitUntil(seconds: 20) { !self.controller.testIsBusy }
        let value = AX.string(element, kAXValueAttribute) ?? ""
        check(!TextAccess.looselyEqual(value, Self.sentence), "rewrite changed the text")
        return true
    }

    /// Switches to Finder and back, like a writer moving on.
    private func leaveAndReturn() async {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
        try? await Task.sleep(for: .seconds(1))
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.TextEdit" }?.activate()
        await waitUntil(seconds: 5) { self.isTestDocument(self.controller.testField?.element) }
    }

    private func expectLatestOutcome(_ kind: Outcome.Kind, _ name: String) async {
        await waitUntil(seconds: 3) { OutcomeStore.shared.recent(limit: 1).first?.kind == kind }
        let latest = OutcomeStore.shared.recent(limit: 1).first
        check(latest?.kind == kind, "\(name) is recorded as \(kind.rawValue) (got \(latest?.kind.rawValue ?? "nothing"))")
        if let final = latest?.final { log("  writer's version recorded: \(final.debugDescription)") }
    }

    private func closeTextEditDocument(_ element: AXUIElement) {
        guard isTestDocument(element), let window = AX.element(element, kAXWindowAttribute),
              let close = AX.element(window, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(close, kAXPressAction as CFString)
    }

    // MARK: - Helpers

    private func check(_ condition: Bool, _ name: String) {
        if !condition { failures += 1 }
        log("\(condition ? "ok  " : "FAIL") \(name)")
    }

    private func log(_ message: String) {
        Log.shared.add("SELFTEST \(message)")
    }

    private func waitUntil(seconds: Double, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
