import AppKit
import ApplicationServices

/// A focused text field that Nudge should show its icon next to.
struct FocusedField: Equatable {
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let role: String
    let bundleID: String?
    /// The web page's host name, for fields inside a web page.
    let site: String?
    /// Browsers and Electron apps: write by pasting, not through Accessibility.
    let prefersPaste: Bool
    /// The part of the field the user can see, in Accessibility coordinates
    /// (origin at the top-left of the primary screen).
    let visibleFrame: CGRect
}

/// Watches the frontmost app for the focused UI element and reports when
/// it is an editable text field, and where it is on screen.
///
/// Focus changes arrive through an AXObserver on the frontmost app. A light
/// timer also re-reads the field's frame, which covers scrolling (there is no
/// reliable scroll notification) and apps that skip focus notifications.
@MainActor
final class FocusTracker: NSObject {
    /// Called with the field to decorate, or nil to hide the icon.
    var onChange: ((FocusedField?) -> Void)?
    /// True for an app (bundle ID) or website (host) where Nudge is turned off.
    var isOff: ((String?, String?) -> Bool)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var appName = ""
    private var bundleID: String?
    private var pid: pid_t = 0
    private var appIsElectron = false
    private var focusedIsWeb = false
    private var focusedSite: String?
    private var focused: AXUIElement?
    private var focusedIsEditable = false
    private var focusedRole = ""
    /// Ancestors that clip the field, such as scroll areas and the window.
    private var clipAncestors: [AXUIElement] = []
    private var lastReported: FocusedField?
    private var lastLogLine = ""
    private var timer: Timer?
    private var tick = 0
    private var webAccessibilityEnabled = Set<pid_t>()

    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static let browserBundleIDs: Set<String> = chromiumBundleIDs.union([
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
    ])
    /// Apps built on Microsoft's Edge web engine (new Teams). Like Chrome, they
    /// hide their text fields until AXEnhancedUserInterface is turned on.
    private static let edgeWebViewBundleIDs: Set<String> = [
        "com.microsoft.teams2", "com.microsoft.teams",
    ]

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        timer = Timer.scheduledTimer(
            timeInterval: 0.1, target: self, selector: #selector(timerFired),
            userInfo: nil, repeats: true)
        attach(to: NSWorkspace.shared.frontmostApplication)
    }

    /// Looks at the frontmost app again, for example after the off list changed.
    func refresh() {
        guard timer != nil else { return }
        lastLogLine = ""
        attach(to: NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate()
        timer = nil
        detach()
        report(nil)
    }

    // MARK: - App tracking

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        attach(to: app)
    }

    private func attach(to app: NSRunningApplication?) {
        detach()
        report(nil)
        guard let app, app.processIdentifier != getpid() else { return }

        pid = app.processIdentifier
        appName = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
        bundleID = app.bundleIdentifier
        appIsElectron = app.bundleURL.map {
            FileManager.default.fileExists(
                atPath: $0.appending(path: "Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        // Turned off in this app: don't watch it at all.
        if isOff?(bundleID, nil) == true {
            logOnce("\(appName) | Nudge is off in this app")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        appElement = element
        enableWebAccessibility(element, pid: pid)

        var newObserver: AXObserver?
        let error = AXObserverCreate(pid, axObserverCallback, &newObserver)
        guard error == .success, let newObserver else {
            Log.shared.add("\(appName): could not watch this app (AXError \(error.rawValue))")
            return
        }
        observer = newObserver
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXApplicationHiddenNotification,
        ]
        for name in notifications {
            AXObserverAddNotification(newObserver, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        refreshFocus(force: true)
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        focused = nil
        focusedIsEditable = false
        clipAncestors = []
    }

    /// Chrome and Electron apps build their accessibility tree only on request.
    private func enableWebAccessibility(_ app: AXUIElement, pid: pid_t) {
        guard !webAccessibilityEnabled.contains(pid) else { return }
        // Electron apps (Slack, VS Code, and others) honour AXManualAccessibility.
        let manual = AX.setBool(app, "AXManualAccessibility", true)
        var enhanced: AXError?
        if let bundleID, Self.chromiumBundleIDs.union(Self.edgeWebViewBundleIDs).contains(bundleID) {
            enhanced = AX.setBool(app, "AXEnhancedUserInterface", true)
        }
        // Teams can refuse while it is still starting, so it is tried again next time.
        let isEdgeWebView = bundleID.map(Self.edgeWebViewBundleIDs.contains) ?? false
        if !isEdgeWebView || manual == .success || enhanced == .success {
            webAccessibilityEnabled.insert(pid)
        }
        Log.shared.add("\(appName) | accessibility setup | bundle \(bundleID ?? "unknown") | AXManualAccessibility=\(manual.rawValue) | AXEnhancedUserInterface=\(enhanced.map { String($0.rawValue) } ?? "not requested")")
        if manual == .success || enhanced == .success {
            Log.shared.add("\(appName): turned on web accessibility")
        }
    }

    // MARK: - Events

    fileprivate func handle(notification: String) {
        switch notification {
        case kAXApplicationHiddenNotification:
            report(nil)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            refreshFrame()
        default:
            refreshFocus(force: false)
        }
    }

    @objc private func timerFired() {
        tick += 1
        if tick % 5 == 0 {
            refreshFocus(force: false)  // every 0.5 s, in case a notification was missed
        } else {
            refreshFrame()
        }
    }

    // MARK: - Focus

    private func refreshFocus(force: Bool) {
        guard let appElement else { return }
        let focusResult = AX.elementResult(appElement, kAXFocusedUIElementAttribute)
        let element = focusResult.element ?? systemWideFocus()
        if !force, let element, let focused, CFEqual(element, focused) {
            refreshFrame()
            return
        }

        focused = element
        guard let element else {
            focusedIsEditable = false
            clipAncestors = []
            logOnce("\(appName) | nothing focused | AXFocusedUIElement: \(focusResult.diagnostic)")
            report(nil)
            return
        }

        AXUIElementSetMessagingTimeout(element, 0.25)
        let role = AX.string(element, kAXRoleAttribute) ?? "?"
        let subrole = AX.string(element, kAXSubroleAttribute)
        let (editable, reason) = classify(element, role: role, subrole: subrole)
        focusedRole = subrole.map { "\(role)/\($0)" } ?? role
        focusedIsEditable = editable
        (clipAncestors, focusedIsWeb, focusedSite) = editable ? scanAncestors(of: element) : ([], false, nil)

        let frameText = AX.frame(element).map(Self.describe) ?? "no frame"
        logOnce("\(appName) | \(focusedRole) | \(editable ? "text field" : "not a text field"): \(reason) | \(frameText)")
        refreshFrame()
    }

    /// Some apps (new Teams) answer the app-level focus question with "no value"
    /// but still answer the system-wide one. Use it only when it is this app's.
    private func systemWideFocus() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let element = AX.element(system, kAXFocusedUIElementAttribute) else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        return element
    }

    private func classify(_ element: AXUIElement, role: String, subrole: String?) -> (Bool, String) {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return (false, "password field, skipped")
        }
        let valueSettable = AX.isSettable(element, kAXValueAttribute)
        if Self.textRoles.contains(role) {
            return valueSettable ? (true, "editable") : (false, "read-only")
        }
        // Rich text editors on web pages (contenteditable) often use other roles.
        // Their value must be text: switches and sliders have settable number values.
        // That check reads the value, so it never runs on a website where Nudge is off.
        if valueSettable, AX.hasAttribute(element, kAXSelectedTextRangeAttribute) {
            if isOff?(bundleID, scanAncestors(of: element).2) == true {
                return (false, "Nudge is off on this site")
            }
            if AX.string(element, kAXValueAttribute) != nil {
                return (true, "editable content")
            }
        }
        return (false, "role not editable")
    }

    /// Finds the scroll areas and window that bound what the user can see of
    /// a field (a long TextEdit document is much taller than its window), and
    /// whether the field sits inside a web page.
    private func scanAncestors(of element: AXUIElement) -> ([AXUIElement], Bool, String?) {
        var result: [AXUIElement] = []
        var isWeb = false
        var site: String?
        var current = AX.element(element, kAXParentAttribute)
        var depth = 0
        while let node = current, depth < 40 {
            let role = AX.string(node, kAXRoleAttribute)
            if role == "AXScrollArea" || role == "AXWindow" {
                result.append(node)
            }
            if role == "AXWebArea" {
                isWeb = true
                if site == nil { site = AX.url(node)?.host() }
            }
            if role == "AXWindow" || role == "AXApplication" { break }
            current = AX.element(node, kAXParentAttribute)
            depth += 1
        }
        return (result, isWeb, site)
    }

    private func refreshFrame() {
        guard focusedIsEditable, let focused, var rect = AX.frame(focused) else {
            report(nil)
            return
        }
        for ancestor in clipAncestors {
            guard let clip = AX.frame(ancestor) else { continue }
            rect = rect.intersection(clip)
        }
        guard !rect.isNull, rect.width >= 8, rect.height >= 8 else {
            report(nil)
            return
        }
        // Turned off on this website: hide everything.
        if isOff?(bundleID, focusedSite) == true {
            logOnce("\(appName) | Nudge is off on \(focusedSite ?? "this site")")
            report(nil)
            return
        }
        let isBrowser = bundleID.map {
            Self.browserBundleIDs.contains($0) || Self.edgeWebViewBundleIDs.contains($0)
        } ?? false
        report(FocusedField(
            element: focused, pid: pid, appName: appName, role: focusedRole,
            bundleID: bundleID, site: focusedSite,
            prefersPaste: focusedIsWeb || appIsElectron || isBrowser,
            visibleFrame: rect))
    }

    // MARK: - Output

    private func report(_ field: FocusedField?) {
        guard field != lastReported else { return }
        lastReported = field
        onChange?(field)
    }

    private func logOnce(_ line: String) {
        guard line != lastLogLine else { return }
        lastLogLine = line
        Log.shared.add(line)
    }

    private static func describe(_ r: CGRect) -> String {
        "frame \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
    }
}

/// C callback for AXObserver. It runs on the main run loop, where the
/// observer's source was added, so the tracker can be used directly.
private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        tracker.handle(notification: name)
    }
}
