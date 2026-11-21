import AppKit
import SwiftUI

/// The small Nudge icon that sits at the bottom-right corner of the
/// focused text field. It never takes focus and, in Stage 1, ignores clicks.
/// It appears, moves and hides instantly: it is seen too often to animate.
@MainActor
final class IconPanel: NSPanel {
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
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: NudgeIcon())
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
        // Accessibility y grows down from the primary screen's top;
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

private struct NudgeIcon: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor)
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 18, height: 18)
    }
}
