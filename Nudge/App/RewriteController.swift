import AppKit
import ApplicationServices

/// Runs the Stage 2 loop: click the icon, pick an action, rewrite the text
/// on device, and put it back in the field, with Undo.
@MainActor
final class RewriteController {
    private let icon = IconPanel()
    private let popover = ActionPopover()
    private let keys = EscapeKeyTap()

    private var field: FocusedField?
    private var work: Task<Void, Never>?
    private var undo: UndoRecord?
    private var mouseMonitor: Any?
    private var feedbackReset: Task<Void, Never>?

    private static let undoWindow: TimeInterval = 30

    private struct UndoRecord {
        let element: AXUIElement
        let appName: String
        let mode: CapturedText.Mode
        let original: String
        let replacement: String
        /// Where the replacement starts, in UTF-16 units (selection mode).
        let location: Int?
        let prefersPaste: Bool
        let date: Date
    }

    init() {
        icon.onClick = { [weak self] in self?.iconClicked() }
        popover.onAction = { [weak self] in self?.run($0) }
        popover.onUndo = { [weak self] in self?.performUndo() }
        keys.onEscape = { [weak self] in self?.escapePressed() }
        keys.onOtherKey = { [weak self] in
            // Typing while the menu is open closes it. The key still reaches the app.
            if self?.work == nil { self?.closePopover() }
        }
    }

    // MARK: - Focus

    func fieldChanged(_ newField: FocusedField?) {
        let sameElement = newField?.element == field?.element
        field = newField
        guard let newField else {
            icon.hide()
            closePopover()
            return
        }
        icon.show(for: newField.visibleFrame)
        if popover.isVisible {
            if sameElement {
                popover.follow(icon.frame)
            } else {
                closePopover()
            }
        }
    }

    // MARK: - Popover

    private func iconClicked() {
        guard work == nil else { return }
        if popover.isVisible {
            closePopover()
        } else {
            openPopover(message: nil)
        }
    }

    private func openPopover(message: String?) {
        let unavailable = Rewriter.unavailableMessage
        popover.model.message = message ?? unavailable
        popover.model.actionsEnabled = unavailable == nil
        popover.model.canUndo = undoIsAvailable
        popover.show(near: icon.frame)
        keys.arm()
        if mouseMonitor == nil {
            // A click anywhere outside Nudge closes the popover.
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePopover() }
            }
        }
    }

    private func closePopover() {
        popover.hide()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if work == nil { keys.disarm() }
    }

    private func escapePressed() {
        if let work {
            work.cancel()
        } else {
            closePopover()
        }
    }

    // MARK: - Rewrite

    private func run(_ action: RewriteAction) {
        closePopover()
        guard let field else { return }
        guard let captured = TextAccess.capture(from: field.element) else {
            fail("Nudge could not read the text in this field.", log: "\(action.logName) | \(field.appName) | could not read text")
            return
        }
        guard !captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("There is no text to rewrite yet.", log: nil)
            return
        }
        let count = captured.text.count
        guard count <= Rewriter.maxCharacters else {
            fail(
                "This text is too long for now (\(count.formatted()) characters). Select up to \(Rewriter.maxCharacters.formatted()) characters and try again.",
                log: "\(action.logName) | \(field.appName) | skipped, \(count) chars is over the limit")
            return
        }

        feedbackReset?.cancel()
        icon.model.state = .working
        keys.arm()
        let started = ContinuousClock.now

        work = Task { [weak self] in
            do {
                let result = try await Rewriter.rewrite(captured.text, action: action)
                try Task.checkCancellation()
                try await self?.apply(result, for: captured, action: action, in: field, started: started)
            } catch is CancellationError {
                self?.finishWork()
                self?.icon.model.state = .idle
                Log.shared.add("\(action.logName) | \(field.appName) | cancelled, text untouched")
            } catch {
                self?.finishWork()
                self?.fail(error.localizedDescription, log: "\(action.logName) | \(field.appName) | failed: \(error.localizedDescription)")
            }
        }
    }

    private func apply(
        _ result: String, for captured: CapturedText, action: RewriteAction,
        in field: FocusedField, started: ContinuousClock.Instant
    ) async throws {
        let seconds = (ContinuousClock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
        let counts = "\(captured.text.count) → \(result.count) chars"

        // Never write into a different field than the one the text came from.
        guard let current = AX.focusedElement(pid: field.pid), current == field.element else {
            finishWork()
            fail("You moved to another field, so Nudge did not change anything.",
                 log: "\(action.logName) | \(field.appName) | focus moved, result discarded")
            return
        }
        // Never overwrite typing that happened while the model was working.
        if !textIsUnchanged(captured, in: field.element) {
            finishWork()
            fail("The text changed while Nudge was working, so nothing was replaced.",
                 log: "\(action.logName) | \(field.appName) | text changed during rewrite, result discarded")
            return
        }
        if result == captured.text {
            finishWork()
            flash(.success)
            Log.shared.add("\(action.logName) | \(field.appName) | \(counts) | \(seconds) | no changes needed")
            return
        }

        let target: WriteTarget = captured.mode == .whole
            ? .whole(current: captured.fullValue)
            : .selection(range: captured.range, old: captured.text)
        do {
            let method = try await TextWriter.replace(
                target, with: result, in: field.element, preferPaste: field.prefersPaste)
            undo = UndoRecord(
                element: field.element, appName: field.appName, mode: captured.mode,
                original: captured.text, replacement: result, location: captured.range?.location,
                prefersPaste: field.prefersPaste, date: Date())
            finishWork()
            flash(.success)
            Log.shared.add("\(action.logName) | \(field.appName) | \(captured.mode.rawValue) | \(counts) | \(seconds) | wrote via \(method.rawValue)")
        } catch {
            finishWork()
            fail(error.localizedDescription, log: "\(action.logName) | \(field.appName) | write failed: \(error.localizedDescription)")
        }
    }

    private func textIsUnchanged(_ captured: CapturedText, in element: AXUIElement) -> Bool {
        switch captured.mode {
        case .whole:
            guard let before = captured.fullValue, let now = AX.string(element, kAXValueAttribute) else { return true }
            return before == now
        case .selection:
            guard let now = AX.string(element, kAXSelectedTextAttribute) else { return true }
            return now == captured.text
        }
    }

    private func finishWork() {
        work = nil
        if !popover.isVisible { keys.disarm() }
    }

    // MARK: - Undo

    private var undoIsAvailable: Bool {
        guard let undo, let field else { return false }
        return undo.element == field.element && Date().timeIntervalSince(undo.date) < Self.undoWindow
    }

    private func performUndo() {
        closePopover()
        guard let record = undo, undoIsAvailable else {
            fail("Undo is no longer available. Try Command-Z.", log: nil)
            return
        }
        undo = nil
        let value = AX.string(record.element, kAXValueAttribute)
        let target: WriteTarget

        switch record.mode {
        case .whole:
            guard value == nil || value == record.replacement else {
                fail("The text has changed since the rewrite, so Nudge cannot undo it safely. Try Command-Z.",
                     log: "Undo | \(record.appName) | text changed, not undone")
                return
            }
            target = .whole(current: value)
        case .selection:
            let length = TextAccess.utf16Length(record.replacement)
            guard let value, let location = record.location,
                  TextAccess.substring(of: value, range: CFRange(location: location, length: length)) == record.replacement
            else {
                fail("Nudge cannot find the rewritten text any more, so it cannot undo safely. Try Command-Z.",
                     log: "Undo | \(record.appName) | rewritten text not found, not undone")
                return
            }
            target = .selection(range: CFRange(location: location, length: length), old: record.replacement)
        }

        icon.model.state = .working
        work = Task { [weak self] in
            do {
                let method = try await TextWriter.replace(
                    target, with: record.original, in: record.element, preferPaste: record.prefersPaste)
                self?.finishWork()
                self?.flash(.success)
                Log.shared.add("Undo | \(record.appName) | restored original via \(method.rawValue)")
            } catch {
                self?.finishWork()
                self?.fail(error.localizedDescription, log: "Undo | \(record.appName) | failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Feedback

    /// Shows a problem: the icon turns orange and the popover explains.
    private func fail(_ message: String, log: String?) {
        if let log { Log.shared.add(log) }
        flash(.failure)
        if field != nil {
            openPopover(message: message)
        }
    }

    /// A quick, quiet confirmation on the icon, then back to idle.
    private func flash(_ state: IconModel.State) {
        feedbackReset?.cancel()
        icon.model.state = state
        feedbackReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(state == .success ? 1.2 : 2))
            guard !Task.isCancelled else { return }
            self?.icon.model.state = .idle
        }
    }
}
