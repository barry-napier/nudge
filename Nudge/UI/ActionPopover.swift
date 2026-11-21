import AppKit
import Observation
import SwiftUI

/// One row in the menu.
enum MenuItem: Hashable, Identifiable {
    case undo
    case action(RewriteAction)
    case custom

    var id: String {
        switch self {
        case .undo: "undo"
        case .action(let action): action.rawValue
        case .custom: "custom"
        }
    }

    var title: String {
        switch self {
        case .undo: "Undo last change"
        case .action(let action): action.title
        case .custom: "Custom instruction…"
        }
    }

    var symbol: String {
        switch self {
        case .undo: "arrow.uturn.backward"
        case .action(let action): action.symbol
        case .custom: "text.cursor"
        }
    }

    /// The number key that picks this row.
    var number: Int? {
        switch self {
        case .undo: nil
        case .action(let action): (RewriteAction.allCases.firstIndex(of: action) ?? 0) + 1
        case .custom: RewriteAction.allCases.count + 1
        }
    }
}

@MainActor
@Observable
final class PopoverModel {
    /// A note shown above the actions, such as an error.
    var message: String?
    var actionsEnabled = true
    var items: [MenuItem] = []
    var selected: MenuItem?
    /// The user is typing a custom instruction.
    var isTyping = false
    var customText = ""
    /// Drives the entrance animation.
    var appeared = false
    /// The corner nearest the icon, so the popover grows out of it.
    var anchor: UnitPoint = .topTrailing

    func moveSelection(by step: Int) {
        let choices = items.filter { isEnabled($0) }
        guard !choices.isEmpty else { return }
        let current = selected.flatMap { choices.firstIndex(of: $0) } ?? (step > 0 ? -1 : choices.count)
        let next = (current + step + choices.count) % choices.count
        selected = choices[next]
    }

    func isEnabled(_ item: MenuItem) -> Bool {
        item == .undo || actionsEnabled
    }
}

/// The small menu that opens from the icon or the double-tap.
/// Like the icon, it never takes focus away from the text field.
@MainActor
final class ActionPopover: NSPanel {
    let model = PopoverModel()
    var onPick: ((MenuItem) -> Void)?

    private var host: FirstClickHostingView<ActionMenuView>!
    private var iconFrame: NSRect = .zero
    private let gap: CGFloat = 4

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
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
        let view = ActionMenuView(model: model, onPick: { [weak self] in self?.onPick?($0) })
        host = FirstClickHostingView(rootView: view)
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Opens next to the icon: below it if there is room, otherwise above.
    /// From the keyboard it appears instantly: it is used too often to animate.
    func show(near iconFrame: NSRect, animated: Bool) {
        self.iconFrame = iconFrame
        refit()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            model.appeared = true
            orderFrontRegardless()
            invalidateShadow()
            return
        }
        model.appeared = false
        orderFrontRegardless()
        Task { @MainActor in
            // Let the hidden state render once, so the change can animate.
            try? await Task.sleep(for: .milliseconds(16))
            // A strong ease-out: quick to arrive, gentle to settle.
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)) { self.model.appeared = true }
            self.invalidateShadow()
        }
    }

    /// Follows the icon if the field moves while the popover is open.
    func follow(_ iconFrame: NSRect) {
        self.iconFrame = iconFrame
        place(size: frame.size)
    }

    /// Resizes to fit the content, for example after switching to typing.
    func refit() {
        host.layoutSubtreeIfNeeded()
        place(size: host.fittingSize)
        invalidateShadow()
    }

    /// Dismissal snaps shut. It is the system responding, so it is instant.
    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        model.appeared = false
    }

    private func place(size: NSSize) {
        let icon = iconFrame
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
    let onPick: (MenuItem) -> Void

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
            if model.isTyping {
                CustomInstructionBox(text: model.customText)
            } else {
                ForEach(model.items) { item in
                    MenuRow(
                        item: item,
                        isSelected: model.selected == item,
                        onHover: { if $0 { model.selected = item } },
                        action: { onPick(item) })
                        .disabled(!model.isEnabled(item))
                    if item == .undo {
                        Divider().padding(.vertical, 2)
                    }
                }
            }
            Divider().padding(.vertical, 2)
            Text(model.isTyping
                 ? "Return to run · Esc to go back"
                 : "↑↓ and Return, or a number · Runs on your Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
        }
        .padding(6)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12)))
        .scaleEffect(model.appeared ? 1 : 0.95, anchor: model.anchor)
        .opacity(model.appeared ? 1 : 0)
    }
}

private struct MenuRow: View {
    let item: MenuItem
    let isSelected: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let highlighted = isSelected && isEnabled
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .frame(width: 16)
                    .foregroundStyle(highlighted ? Color.white : Color.accentColor)
                Text(item.title)
                    .foregroundStyle(highlighted ? Color.white : Color.primary)
                Spacer(minLength: 0)
                if let number = item.number {
                    Text("\(number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(highlighted ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover(perform: onHover)
    }
}

/// Shows what the user is typing. The keys come from Nudge's keyboard tap,
/// so the text field in the app keeps its focus and selection.
private struct CustomInstructionBox: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Custom instruction", systemImage: "text.cursor")
                .font(.callout.weight(.medium))
            HStack(spacing: 0) {
                if text.isEmpty {
                    Text("For example: make it sound excited")
                        .foregroundStyle(.secondary)
                } else {
                    Text(text)
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: 15)
                    .padding(.leading, 1)
                Spacer(minLength: 0)
            }
            .lineLimit(3)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
