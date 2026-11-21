import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PopoverModel {
    /// A note shown above the actions, such as an error.
    var message: String?
    var actionsEnabled = true
    var canUndo = false
    /// Drives the entrance animation.
    var appeared = false
    /// The corner nearest the icon, so the popover grows out of it.
    var anchor: UnitPoint = .topTrailing
}

/// The small menu that opens when the user clicks the icon.
/// Like the icon, it never takes focus away from the text field.
@MainActor
final class ActionPopover: NSPanel {
    let model = PopoverModel()
    var onAction: ((RewriteAction) -> Void)?
    var onUndo: (() -> Void)?

    private var host: FirstClickHostingView<ActionMenuView>!
    private let gap: CGFloat = 4

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = ActionMenuView(
            model: model,
            onAction: { [weak self] in self?.onAction?($0) },
            onUndo: { [weak self] in self?.onUndo?() })
        host = FirstClickHostingView(rootView: view)
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Opens next to the icon: below it if there is room, otherwise above.
    func show(near iconFrame: NSRect) {
        model.appeared = false
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        place(size: size, near: iconFrame)
        orderFrontRegardless()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task { @MainActor in
            // Let the hidden state render once, so the change can animate.
            try? await Task.sleep(for: .milliseconds(16))
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.12)) { self.model.appeared = true }
            } else {
                // A strong ease-out: quick to arrive, gentle to settle.
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) { self.model.appeared = true }
            }
            self.invalidateShadow()
        }
    }

    /// Follows the icon if the field moves while the popover is open.
    func follow(_ iconFrame: NSRect) {
        place(size: frame.size, near: iconFrame)
    }

    /// Dismissal snaps shut. It is the system responding, so it is instant.
    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        model.appeared = false
    }

    private func place(size: NSSize, near icon: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .infinite

        var origin = NSPoint(x: icon.maxX - size.width, y: icon.minY - gap - size.height)
        var vertical: CGFloat = 0  // 0 = top edge of the popover is nearest the icon
        if origin.y < bounds.minY {
            origin.y = icon.maxY + gap
            vertical = 1
        }
        var horizontal: CGFloat = 1  // 1 = trailing edge is nearest the icon
        if origin.x < bounds.minX {
            origin.x = icon.minX
            horizontal = 0
        }
        origin.x = min(origin.x, bounds.maxX - size.width)
        model.anchor = UnitPoint(x: horizontal, y: vertical)
        setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }
}

/// Takes clicks on the first try, even though Nudge is never the active app.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct ActionMenuView: View {
    let model: PopoverModel
    let onAction: (RewriteAction) -> Void
    let onUndo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                Divider().padding(.vertical, 2)
            }
            if model.canUndo {
                MenuRow(title: "Undo last change", symbol: "arrow.uturn.backward", action: onUndo)
                Divider().padding(.vertical, 2)
            }
            ForEach(RewriteAction.allCases) { action in
                MenuRow(title: action.title, symbol: action.symbol) { onAction(action) }
                    .disabled(!model.actionsEnabled)
            }
            Divider().padding(.vertical, 2)
            Text("Runs on your Mac. Nothing is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
        }
        .padding(6)
        .frame(width: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12)))
        .scaleEffect(model.appeared ? 1 : 0.95, anchor: model.anchor)
        .opacity(model.appeared ? 1 : 0)
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(isHovered ? Color.white : Color.accentColor)
                Text(title)
                    .foregroundStyle(isHovered ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 && isEnabled }
    }
}
