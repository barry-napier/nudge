import AppKit
import CoreGraphics

/// Catches the Escape key while the popover is open or a rewrite is running,
/// so it can close or cancel without reaching the app underneath.
/// Other keys pass through untouched. The tap is off at all other times.
@MainActor
final class EscapeKeyTap {
    var onEscape: (() -> Void)?
    /// Any other key was pressed while armed. The key still reaches the app.
    var onOtherKey: (() -> Void)?

    private var tap: CFMachPort?
    private var isArmed = false
    private var swallowNextEscapeUp = false
    private static let escapeKeyCode: Int64 = 53

    func arm() {
        if tap == nil { create() }
        guard let tap else { return }
        isArmed = true
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disarm() {
        isArmed = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    private func create() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: escapeTapCallback, userInfo: refcon)
        else {
            Log.shared.add("Could not watch the Escape key. Escape will not cancel.")
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: false)
    }

    /// Returns true to swallow the event. Must stay fast, or macOS turns the tap off.
    fileprivate func handle(type: CGEventType, keyCode: Int64) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if isArmed, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyDown where isArmed:
            if keyCode == Self.escapeKeyCode {
                swallowNextEscapeUp = true
                Task { @MainActor in self.onEscape?() }
                return true
            }
            Task { @MainActor in self.onOtherKey?() }
            return false
        case .keyUp where keyCode == Self.escapeKeyCode && swallowNextEscapeUp:
            swallowNextEscapeUp = false
            return true
        default:
            return false
        }
    }
}

private func escapeTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<EscapeKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let swallow = MainActor.assumeIsolated { owner.handle(type: type, keyCode: keyCode) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
