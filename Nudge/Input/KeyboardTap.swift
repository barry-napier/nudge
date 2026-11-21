import AppKit
import CoreGraphics

/// The key that opens the menu when tapped twice.
enum TriggerKey: String, CaseIterable, Identifiable, Sendable {
    case rightControl
    case rightOption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightControl: "Right Control"
        case .rightOption: "Right Option"
        }
    }

    fileprivate var keyCode: Int64 {
        switch self {
        case .rightControl: 62
        case .rightOption: 61
        }
    }

    /// Device bit that is set while this exact key is held.
    fileprivate var deviceMask: UInt64 {
        switch self {
        case .rightControl: 0x2000
        case .rightOption: 0x40
        }
    }

    /// The general modifier flag this key sets.
    fileprivate var modifierFlag: UInt64 {
        switch self {
        case .rightControl: CGEventFlags.maskControl.rawValue
        case .rightOption: CGEventFlags.maskAlternate.rawValue
        }
    }
}

/// One system-wide keyboard tap for everything Nudge does with keys:
/// the double-tap trigger, and the keys the menu uses while it is open.
///
/// Normal typing is never touched. Keys are only held back from the app
/// while the menu is open (arrows, Return, Escape, 1 to 8), while the user
/// types a custom instruction, and Escape while a rewrite runs.
@MainActor
final class KeyboardTap {
    enum Mode {
        /// Watch for the double-tap only. Every key passes through.
        case idle
        /// The menu is open.
        case menu
        /// The user is typing a custom instruction into the menu.
        case typing
        /// A rewrite is running. Escape cancels it.
        case working
    }

    enum Key {
        case up
        case down
        case enter
        case escape
        case backspace
        case number(Int)
        case text(String)
        case paste
    }

    var mode: Mode = .idle
    var trigger: TriggerKey = .rightOption
    var onDoubleTap: (() -> Void)?
    /// A key Nudge kept from the app.
    var onKey: ((Key) -> Void)?
    /// Any other key pressed while the menu is open. It still reaches the app.
    var onOtherKey: (() -> Void)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var swallowedKeyUps = Set<Int64>()

    // Double-tap state.
    private var triggerDownAt: TimeInterval?
    private var lastTapUpAt: TimeInterval?
    private var isSecondTap = false
    private static let maxHold: TimeInterval = 0.3
    private static let maxGap: TimeInterval = 0.3

    private static let numberKeyCodes: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8,
    ]

    @discardableResult
    func start() -> Bool {
        if tap == nil { create() }
        guard let tap else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        isRunning = false
        mode = .idle
        resetDoubleTap()
    }

    private func create() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: keyboardTapCallback, userInfo: refcon)
        else {
            Log.shared.add("Could not watch the keyboard. Double-tap and menu keys will not work.")
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    // MARK: - Event handling (must stay fast, or macOS turns the tap off)

    /// Returns true to keep the event from the app.
    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: UInt64, text: String?) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if isRunning, let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.shared.add("Keyboard watch was paused by macOS. Turned it back on.")
            }
            return false
        case .flagsChanged:
            handleModifier(keyCode: keyCode, flags: flags)
            return false
        case .keyDown:
            resetDoubleTap()  // another key between taps cancels the double-tap
            let keep = handleKeyDown(keyCode: keyCode, flags: flags, text: text)
            if keep { swallowedKeyUps.insert(keyCode) }
            return keep
        case .keyUp:
            return swallowedKeyUps.remove(keyCode) != nil
        default:
            return false
        }
    }

    private func handleModifier(keyCode: Int64, flags: UInt64) {
        guard keyCode == trigger.keyCode else {
            resetDoubleTap()  // a different modifier key
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isDown = flags & trigger.deviceMask != 0
        if isDown {
            let otherModifiers: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
                | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskSecondaryFn.rawValue
            let leftTwin: UInt64 = trigger == .rightControl ? 0x1 : 0x20
            if flags & (otherModifiers & ~trigger.modifierFlag) != 0 || flags & leftTwin != 0 {
                resetDoubleTap()
                return
            }
            isSecondTap = lastTapUpAt.map { now - $0 <= Self.maxGap } ?? false
            triggerDownAt = now
        } else {
            guard let downAt = triggerDownAt else { return }
            triggerDownAt = nil
            guard now - downAt <= Self.maxHold else {
                resetDoubleTap()  // held, not tapped
                return
            }
            if isSecondTap {
                resetDoubleTap()
                Task { @MainActor in self.onDoubleTap?() }
            } else {
                lastTapUpAt = now
            }
        }
    }

    private func resetDoubleTap() {
        triggerDownAt = nil
        lastTapUpAt = nil
        isSecondTap = false
    }

    private func handleKeyDown(keyCode: Int64, flags: UInt64, text: String?) -> Bool {
        let command = flags & CGEventFlags.maskCommand.rawValue != 0
        let control = flags & CGEventFlags.maskControl.rawValue != 0

        switch mode {
        case .idle:
            return false

        case .working:
            guard keyCode == 53 else { return false }
            send(.escape)
            return true

        case .menu:
            if command || control {
                Task { @MainActor in self.onOtherKey?() }
                return false
            }
            switch keyCode {
            case 126: send(.up)
            case 125: send(.down)
            case 36, 76: send(.enter)
            case 53: send(.escape)
            default:
                if let number = Self.numberKeyCodes[keyCode] {
                    send(.number(number))
                } else {
                    Task { @MainActor in self.onOtherKey?() }
                    return false
                }
            }
            return true

        case .typing:
            // Every key goes to Nudge's instruction box, so nothing leaks into the app.
            switch keyCode {
            case 36, 76: send(.enter)
            case 53: send(.escape)
            case 51: send(.backspace)
            case 9 where command: send(.paste)
            default:
                if !command, !control, let text, !text.isEmpty,
                   text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    send(.text(text))
                }
            }
            return true
        }
    }

    private func send(_ key: Key) {
        Task { @MainActor in self.onKey?(key) }
    }
}

private func keyboardTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<KeyboardTap>.fromOpaque(refcon).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.rawValue
    var text: String?
    if type == .keyDown {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        text = String(utf16CodeUnits: chars, count: length)
    }
    let keep = MainActor.assumeIsolated {
        owner.handle(type: type, keyCode: keyCode, flags: flags, text: text)
    }
    return keep ? nil : Unmanaged.passUnretained(event)
}
