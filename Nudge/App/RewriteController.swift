import AppKit
import ApplicationServices

/// Runs the rewrite loop: open the menu (click the icon, or double-tap the
/// trigger key), pick an action, rewrite the text on device, and put it back
/// in the field, with Undo.
@MainActor
final class RewriteController {
    private let icon = IconPanel()
    private let popover = ActionPopover()
    let keys = KeyboardTap()

    private var field: FocusedField?
    private var work: Task<Void, Never>?
    private var undo: UndoRecord?
    private var mouseMonitor: Any?
    private var feedbackReset: Task<Void, Never>?

    private static let undoWindow: TimeInterval = 30
    private static let lastChoiceKey = "lastMenuChoice"
    private static let lastCustomKey = "lastCustomInstruction"

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
        popover.onPick = { [weak self] in self?.pick($0) }
        keys.onDoubleTap = { [weak self] in self?.doubleTapped() }
        keys.onKey = { [weak self] in self?.keyPressed($0) }
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
        Log.shared.add("Icon clicked | \(field?.appName ?? "no field")\(work != nil ? " | busy, ignored" : "")")
        guard work == nil else { return }
        if popover.isVisible {
            closePopover()
        } else {
            openPopover(message: nil, fromKeyboard: false)
        }
    }

    private func doubleTapped() {
        Log.shared.add("Double-tap \(keys.trigger.title) | \(field?.appName ?? "no text field focused")\(work != nil ? " | busy, ignored" : "")")
        guard work == nil, field != nil else { return }
        if popover.isVisible {
            closePopover()
        } else {
            openPopover(message: nil, fromKeyboard: true)
        }
    }

    private func openPopover(message: String?, fromKeyboard: Bool = false) {
        let unavailable = Rewriter.unavailableMessage
        let model = popover.model
        model.message = message ?? unavailable
        model.actionsEnabled = unavailable == nil
        model.isTyping = false
        model.items = (undoIsAvailable ? [.undo] : []) + RewriteAction.allCases.map { .action($0) } + [.custom]
        // The last choice is preselected, so double-tap then Return repeats it.
        model.selected = model.actionsEnabled ? lastChoice : (undoIsAvailable ? .undo : nil)
        popover.show(near: icon.frame, animated: !fromKeyboard)
        Log.shared.add("Menu opened\(fromKeyboard ? " from keyboard" : "")\(model.message.map { " | message: \($0)" } ?? "")")
        keys.mode = .menu
        if mouseMonitor == nil {
            // A click anywhere outside Nudge closes the popover.
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePopover() }
            }
        }
    }

    private func closePopover() {
        if popover.isVisible { Log.shared.add("Menu closed") }
        popover.hide()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        popover.model.isTyping = false
        keys.mode = work == nil ? .idle : .working
    }

    // MARK: - Keys and picks

    private func keyPressed(_ key: KeyboardTap.Key) {
        if let work {
            if case .escape = key { work.cancel() }
            return
        }
        let model = popover.model
        guard popover.isVisible else { return }

        if model.isTyping {
            switch key {
            case .escape:
                model.isTyping = false
                keys.mode = .menu
                popover.refit()
            case .enter:
                let instruction = model.customText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instruction.isEmpty else { return }
                UserDefaults.standard.set(instruction, forKey: Self.lastCustomKey)
                remember(.custom)
                run(.custom(instruction))
            case .backspace:
                if !model.customText.isEmpty { model.customText.removeLast() }
            case .text(let text):
                if model.customText.count < 200 { model.customText += text }
            case .paste:
                if let pasted = NSPasteboard.general.string(forType: .string) {
                    let line = pasted.replacingOccurrences(of: "\n", with: " ")
                    model.customText = String((model.customText + line).prefix(200))
                }
            case .up, .down, .number:
                break
            }
            return
        }

        switch key {
        case .up: model.moveSelection(by: -1)
        case .down: model.moveSelection(by: 1)
        case .enter: if let item = model.selected { pick(item) }
        case .escape: closePopover()
        case .number(let number):
            if let item = model.items.first(where: { $0.number == number }) { pick(item) }
        default: break
        }
    }

    private func pick(_ item: MenuItem) {
        guard popover.model.isEnabled(item) else { return }
        switch item {
        case .undo:
            performUndo()
        case .action(let action):
            remember(item)
            run(.preset(action))
        case .custom:
            let model = popover.model
            model.selected = .custom
            model.customText = UserDefaults.standard.string(forKey: Self.lastCustomKey) ?? ""
            model.isTyping = true
            keys.mode = .typing
            popover.refit()
            Log.shared.add("Custom instruction box opened")
        }
    }

    private var lastChoice: MenuItem {
        let saved = UserDefaults.standard.string(forKey: Self.lastChoiceKey)
        if saved == MenuItem.custom.id { return .custom }
        return .action(saved.flatMap(RewriteAction.init(rawValue:)) ?? .improve)
    }

    private func remember(_ item: MenuItem) {
        UserDefaults.standard.set(item.id, forKey: Self.lastChoiceKey)
    }

    // MARK: - Rewrite

    private func run(_ action: RewriteRequest) {
        Log.shared.add("Action chosen | \(action.logName)")
        closePopover()
        guard let field else {
            Log.shared.add("\(action.logName) | no text field is focused any more")
            return
        }
        guard let captured = TextAccess.capture(from: field.element) else {
            fail("Nudge could not read the text in this field.", log: "\(action.logName) | \(field.appName) | could not read text")
            return
        }
        guard !captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("There is no text to rewrite yet.", log: "\(action.logName) | \(field.appName) | field is empty")
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
        keys.mode = .working
        let started = ContinuousClock.now

        work = Task { [weak self] in
            do {
                let result = try await Rewriter.rewrite(captured.text, request: action)
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
        _ result: String, for captured: CapturedText, action: RewriteRequest,
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
            logText(before: captured.text, after: result, request: action)
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
            let check = await confirmation(of: result, in: field.element, method: method)
            finishWork()
            flash(.success)
            Log.shared.add("\(action.logName) | \(field.appName) | \(captured.mode.rawValue) | \(counts) | \(seconds) | wrote via \(method.rawValue) | \(check)")
            logText(before: captured.text, after: result, request: action)
        } catch {
            finishWork()
            fail(error.localizedDescription, log: "\(action.logName) | \(field.appName) | write failed: \(error.localizedDescription)")
        }
    }

    /// Reads the field back after a write, for the debug log only.
    private func confirmation(of result: String, in element: AXUIElement, method: WriteMethod) async -> String {
        if method == .paste { await pause(milliseconds: 150) }
        guard let value = AX.string(element, kAXValueAttribute) else { return "check: field unreadable" }
        let probe = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains(probe) ? "check: new text is in the field" : "check: NEW TEXT NOT FOUND in field"
    }

    /// Testing aid. Writes the text itself to the local log, only when the
    /// user has turned on "Log Text for Testing".
    private func logText(before: String, after: String?, request: RewriteRequest) {
        guard UserDefaults.standard.bool(forKey: AppState.logTextKey) else { return }
        if let instruction = request.customInstruction {
            Log.shared.add("    instruction: \(instruction.debugDescription)")
        }
        Log.shared.add("    before: \(before.debugDescription)")
        if let after {
            Log.shared.add("    after:  \(after.debugDescription)")
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
        keys.mode = popover.isVisible ? .menu : .idle
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
        keys.mode = .working
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
