import CoreGraphics

/// Posts keyboard shortcuts to the frontmost app.
/// Posting events needs the Accessibility permission Nudge already has.
enum KeyPoster {
    private static let keyA: CGKeyCode = 0
    private static let keyV: CGKeyCode = 9

    static func paste() { press(keyV, flags: .maskCommand) }
    static func selectAll() { press(keyA, flags: .maskCommand) }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
