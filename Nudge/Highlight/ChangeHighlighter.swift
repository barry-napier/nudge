import AppKit
import ApplicationServices

/// Briefly marks the words a rewrite changed, like a highlighter pen.
///
/// The marks are a see-through window above the app. They take no clicks or
/// keys and never touch the text. They go at the first key press or scroll,
/// or if the text moves, so they are never left over the wrong words.
@MainActor
final class ChangeHighlighter {
    private let panel = HighlightPanel()
    private var task: Task<Void, Never>?
    private var monitor: Any?

    private static let showFor: Duration = .seconds(4)
    private static let fadeIn: TimeInterval = 0.18
    private static let fadeOut: TimeInterval = 0.35
    private static let slowAnswer: Duration = .milliseconds(40)
    /// Busy apps hiccup now and then. An app that is slow more often than this
    /// gets no marks, so it cannot make typing lag.
    private static let hiccupsAllowed = 2

    /// - Parameter visibleFrame: The part of the field on screen, read when
    ///   the marks are drawn because a rewrite can resize the field.
    func show(
        original: String, rewrite: String, location: Int?, in element: AXUIElement,
        visibleFrame: @escaping @MainActor () -> CGRect?
    ) {
        hide()
        // Only notes that a key or scroll happened, never which key.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            // The Command-V that Nudge posts to paste can arrive here late.
            if event.type == .keyDown, event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
                return
            }
            MainActor.assumeIsolated { self?.hide() }
        }
        task = Task { [weak self] in
            guard let marks = await Self.settledMarks(
                original: original, rewrite: rewrite, location: location, in: element)
            else {
                if !Task.isCancelled {
                    Log.shared.add("Highlight | word positions missing or too slow, nothing marked")
                    self?.hide()
                }
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard let area = visibleFrame() else { return hide() }
            let shown = marks.filter { mark in
                let seen = mark.rect.intersection(area)
                return !seen.isNull && seen.height >= mark.rect.height / 2
            }
            guard let first = shown.first, let last = shown.last else { return hide() }

            panel.show(shown.map { $0.rect.intersection(area) }, fadeIn: Self.fadeIn)
            Log.shared.add("Highlight | marked \(shown.count) of \(marks.count) changes")

            let length = AX.characterCount(element)
            var hiccups = 0
            let ends = ContinuousClock.now + Self.showFor
            while ContinuousClock.now < ends {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let asked = ContinuousClock.now
                let isSlow = { ContinuousClock.now - asked >= Self.slowAnswer }
                let unchanged = WordLocator.isInPlace(first) && !isSlow()
                    && WordLocator.isInPlace(last) && AX.characterCount(element) == length
                if isSlow() {
                    hiccups += 1
                    if hiccups > Self.hiccupsAllowed { return hide() }
                } else if !unchanged {
                    return hide()
                }
            }
            panel.fade(over: Self.fadeOut)
            try? await Task.sleep(for: .seconds(Self.fadeOut))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    /// Gone at once. The user or the app did something, so nothing lingers.
    func hide() {
        task?.cancel()
        task = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        panel.clear()
    }

    /// Apps lay out and scroll after a write, so wait until two looks agree.
    private static func settledMarks(
        original: String, rewrite: String, location: Int?, in element: AXUIElement
    ) async -> [WordMark]? {
        var previous: [WordMark] = []
        var hiccups = 0
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return nil }
            let asked = ContinuousClock.now
            let marks = WordLocator.marks(original: original, rewrite: rewrite, location: location, in: element)
            if ContinuousClock.now - asked >= slowAnswer * 2 {
                hiccups += 1
                if hiccups > hiccupsAllowed { return nil }
                continue
            }
            if !marks.isEmpty, marks.count == previous.count,
               zip(marks, previous).allSatisfy({ isClose($0.rect, $1.rect) }) {
                return marks
            }
            previous = marks
        }
        return nil
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5 && abs(a.width - b.width) < 1.5
    }
}

/// The see-through window the marks are drawn in.
@MainActor
private final class HighlightPanel: NSPanel {
    private let marks = MarksView()
    private let bleed: CGFloat = 2

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        // Under Nudge's icon and menu, over the app.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = marks
        // The change is in the field itself. VoiceOver should not find this window.
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Takes rects in Accessibility coordinates, where y grows down.
    func show(_ words: [CGRect], fadeIn: TimeInterval) {
        guard let primary = NSScreen.screens.first, let first = words.first else { return }
        let padded = words.map { $0.insetBy(dx: -bleed, dy: 0) }
        let all = padded.dropFirst().reduce(first.insetBy(dx: -bleed, dy: 0)) { $0.union($1) }.integral
        setFrame(
            NSRect(x: all.minX, y: primary.frame.height - all.maxY, width: all.width, height: all.height),
            display: false)
        marks.rects = padded.map { $0.offsetBy(dx: -all.minX, dy: -all.minY) }
        alphaValue = 0
        orderFrontRegardless()
        animate(to: 1, over: fadeIn)
    }

    func fade(over duration: TimeInterval) {
        animate(to: 0, over: duration)
    }

    func clear() {
        guard isVisible else { return }
        orderOut(nil)
        marks.rects = []
    }

    private func animate(to alpha: CGFloat, over duration: TimeInterval) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = alpha
        }
    }
}

private final class MarksView: NSView {
    var rects: [CGRect] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // It sits over the words, so it is see-through: dark and light text both stay readable.
        NSColor(srgbRed: 0.72, green: 0.95, blue: 0, alpha: 0.38).setFill()
        // One shape, so neighbouring marks don't make a darker seam where they meet.
        let shape = NSBezierPath()
        for rect in rects {
            shape.appendRoundedRect(rect, xRadius: 3, yRadius: 3)
        }
        shape.fill()
    }
}
