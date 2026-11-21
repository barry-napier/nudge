import AppKit
import Observation
import SwiftUI

/// What the icon shows.
@MainActor
@Observable
final class IconModel {
    enum State {
        case idle
        case working
        case success
        case failure
    }

    var state: State = .idle
    var isPressed = false
}

/// The small Nudge icon at the bottom-right corner of the focused text field.
/// It never takes focus, so the field keeps its cursor and selection.
/// It appears, moves and hides instantly: it is seen too often to animate.
@MainActor
final class IconPanel: NSPanel {
    let model = IconModel()
    var onClick: (() -> Void)?

    private let iconSize: CGFloat = 18
    private let inset: CGFloat = 4

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 18, height: 18),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = IconClickView(model: model)
        view.onClick = { [weak self] in self?.onClick?() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the icon for a field frame in Accessibility coordinates.
    func show(for fieldFrame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let x = fieldFrame.maxX - iconSize - inset
        // Short single-line fields: centre the icon vertically.
        let topY = fieldFrame.height < iconSize + inset * 2
            ? fieldFrame.midY - iconSize / 2
            : fieldFrame.maxY - iconSize - inset
        // Accessibility y grows down from the primary screen's top.
        // AppKit y grows up from its bottom.
        let y = primary.frame.height - topY - iconSize
        let target = NSRect(x: x.rounded(), y: y.rounded(), width: iconSize, height: iconSize)
        if frame != target {
            setFrame(target, display: true, animate: false)
        }
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func hide() {
        if isVisible {
            orderOut(nil)
        }
    }
}

/// Takes clicks on the first try, even though Nudge is never the active app.
@MainActor
private final class IconClickView: NSView {
    var onClick: (() -> Void)?
    private let model: IconModel

    init(model: IconModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        let host = NSHostingView(rootView: NudgeIcon(model: model))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        withAnimation(.easeOut(duration: 0.12)) { model.isPressed = true }
    }

    override func mouseUp(with event: NSEvent) {
        withAnimation(.easeOut(duration: 0.12)) { model.isPressed = false }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

private struct NudgeIcon: View {
    let model: IconModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(background)
            switch model.state {
            case .idle:
                symbol("sparkle")
            case .working:
                if reduceMotion {
                    symbol("ellipsis")
                } else {
                    Spinner()
                }
            case .success:
                symbol("checkmark")
            case .failure:
                symbol("exclamationmark")
            }
        }
        .frame(width: 18, height: 18)
        .scaleEffect(model.isPressed && !reduceMotion ? 0.94 : 1)
    }

    private var background: Color {
        switch model.state {
        case .idle, .working: .accentColor
        case .success: .green
        case .failure: .orange
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
    }
}

/// A small, fast spinner. A quick spin makes the wait feel shorter.
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let degrees = (seconds * 600).truncatingRemainder(dividingBy: 360)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 9, height: 9)
                .rotationEffect(.degrees(degrees))
        }
    }
}
