import ApplicationServices
import Foundation

/// After a rewrite, watches the field for a little while to see what the
/// writer does with it: keep it, edit it, undo it, or try another action.
///
/// It reads the field once a second, only the field that was rewritten, and
/// only while learning is on. Chat apps empty the field when a message is
/// sent, so the last non-empty text seen is what counts.
@MainActor
final class OutcomeWatcher {
    struct Watch {
        let element: AXUIElement
        let bundleID: String
        let appName: String
        let site: String?
        let action: String
        let voice: String?
        let original: String
        let rewrite: String
        /// The whole field right after the write, when readable.
        let afterWrite: String?
        /// Where the rewrite starts in the field, in UTF-16 units.
        let location: Int
        let started: Date
        var lastSeen: String?
    }

    /// Called with each outcome, so learning can count it.
    var onOutcome: ((Outcome) -> Void)?

    private var watch: Watch?
    private var timer: Timer?
    private static let watchSeconds: TimeInterval = 90

    func began(_ newWatch: Watch) {
        finish(forced: nil)
        var newWatch = newWatch
        newWatch.lastSeen = newWatch.afterWrite
        watch = newWatch
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The writer pressed Nudge's Undo.
    func undone() {
        finish(forced: .undone)
    }

    /// The writer ran another action on the same field straight away.
    func rerun(on element: AXUIElement, as action: String) {
        guard let watch, watch.element == element else { return }
        if watch.action == action {
            // Running the same action again is not a "keep". But if the writer
            // edited the text first, that edit still counts.
            tick()
            if let current = self.watch, let (kind, _) = classify(current), kind == .edited {
                finish(forced: nil)
            } else {
                Log.shared.add("Outcome | \(watch.action) | \(watch.appName) | run again, not recorded")
                stop()
            }
        } else {
            finish(forced: .rerun, rerunTo: action)
        }
    }

    /// Focus moved. If it left the watched field, decide now.
    func focusChanged(to element: AXUIElement?) {
        guard let watch, element != watch.element else { return }
        tick()
        finish(forced: nil)
    }

    func stop() {
        watch = nil
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard var current = watch else { return }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(current.element, kAXValueAttribute as CFString, &value)
        if error == .success, let text = value as? String, !text.isEmpty {
            current.lastSeen = text
            watch = current
        } else if error == .invalidUIElement {
            finish(forced: nil)
            return
        }
        if Date().timeIntervalSince(current.started) > Self.watchSeconds {
            finish(forced: nil)
        }
    }

    private func finish(forced: Outcome.Kind?, rerunTo: String? = nil) {
        timer?.invalidate()
        timer = nil
        guard let current = watch else { return }
        watch = nil
        guard let (kind, final) = forced.map({ ($0, nil as String?) }) ?? classify(current) else {
            Log.shared.add("Outcome | \(current.action) | \(current.appName) | could not tell, not recorded")
            return
        }
        let outcome = Outcome(
            bundleID: current.bundleID, appName: current.appName, site: current.site,
            action: current.action, voice: current.voice, kind: kind,
            original: current.original, rewrite: current.rewrite, final: final, rerunTo: rerunTo)
        Log.shared.add("Outcome | \(current.action) | \(current.appName) | \(kind.rawValue)\(rerunTo.map { " as \($0)" } ?? "")")
        if TestingFlags.logText, let final {
            Log.shared.add("    writer's version: \(final.debugDescription)")
        }
        onOutcome?(outcome)
    }

    /// Compares the field now with the field right after the rewrite.
    private func classify(_ watch: Watch) -> (Outcome.Kind, String?)? {
        guard let now = watch.lastSeen else { return nil }
        if TextAccess.looselyContains(now, watch.rewrite) { return (.accepted, nil) }
        if TextAccess.looselyContains(now, watch.original) { return (.undone, nil) }
        guard let after = watch.afterWrite,
              let final = Self.editedSpan(before: after, now: now, location: watch.location,
                                          length: TextAccess.utf16Length(watch.rewrite))
        else { return nil }
        let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (.undone, nil) }
        if trimmed == watch.rewrite.trimmingCharacters(in: .whitespacesAndNewlines) { return (.accepted, nil) }
        return (.edited, trimmed)
    }

    /// The writer's version of the rewritten part: the field now, minus the
    /// text before and after that the edit did not touch.
    static func editedSpan(before: String, now: String, location: Int, length: Int) -> String? {
        let a = before as NSString
        let b = now as NSString
        guard location >= 0, location + length <= a.length else { return nil }
        var prefix = 0
        while prefix < a.length, prefix < b.length, a.character(at: prefix) == b.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.length - prefix, suffix < b.length - prefix,
              a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        let spanEnd = location + length
        // The edit is entirely outside the rewritten part: the rewrite was kept.
        if prefix >= spanEnd || a.length - suffix <= location {
            let shift = prefix >= spanEnd ? 0 : b.length - a.length
            guard location + shift >= 0, location + shift + length <= b.length else { return nil }
            return b.substring(with: NSRange(location: location + shift, length: length))
        }
        let start = min(prefix, location)
        let end = b.length - min(suffix, a.length - spanEnd)
        guard end >= start else { return "" }
        return b.substring(with: NSRange(location: start, length: end - start))
    }
}
