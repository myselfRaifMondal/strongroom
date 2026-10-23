import AppKit
import ApplicationServices
import Carbon.HIToolbox
import StrongroomKit

/// Excludes every window of the app (main window, sheets, panels, alerts, the
/// quick-access overlay) from screenshots, recordings and screen sharing.
@MainActor
enum WindowPrivacy {
    private static var observer: NSObjectProtocol?

    static func install() {
        sweep()
        // Runs after every event-loop pass, so new windows are covered before
        // they are first drawn on screen.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sweep() }
        }
        // didUpdate only fires when events arrive; windows AppKit creates
        // while the app is idle (menu bar backing windows) are caught here.
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { sweep() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    static func sweep() {
        for w in NSApp.windows where w.sharingType != .none {
            w.sharingType = .none
        }
    }

    static func protect(_ window: NSWindow) {
        window.sharingType = .none
    }
}

/// System-wide hotkey through Carbon's RegisterEventHotKey (no Accessibility
/// permission needed, unlike event taps).
final class GlobalHotKey {
    static let kVK_ANSI_Backslash = UInt32(Carbon.kVK_ANSI_Backslash)
    static let optionCommand = UInt32(Carbon.optionKey | Carbon.cmdKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hk = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hk.action() }
            return noErr
        }, 1, &spec, me, &handlerRef)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x5352_484B) /* 'SRHK' */, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Auto-type with CGEvent keyboard events. Never types without first showing
/// the target app and window title and getting an explicit "Type" click, every
/// time. Requires Accessibility permission; without it, refuses and says so.
@MainActor
enum AutoType {
    struct Target {
        let app: NSRunningApplication
        let windowTitle: String?

        var appName: String { app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)" }
    }

    private static var lastExternalApp: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Remembers the last app other than Strongroom that was frontmost, so the
    /// main window can offer to type into it.
    static func startTrackingExternalApps() {
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { lastExternalApp = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app != .current else { return }
            MainActor.assumeIsolated { lastExternalApp = app }
        }
    }

    static func lastExternalTarget() -> Target? {
        guard let app = lastExternalApp, !app.isTerminated else { return nil }
        return Target(app: app, windowTitle: focusedWindowTitle(of: app))
    }

    /// Captured *before* the overlay takes key focus.
    static func captureFrontmost() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication, app != .current else { return lastExternalTarget() }
        return Target(app: app, windowTitle: focusedWindowTitle(of: app))
    }

    /// Needs Accessibility permission; returns nil without it.
    static func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        guard isTrusted else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows the confirmation (every time), then types.
    static func confirmAndType(_ text: String, itemTitle: String, target: Target?, beforeTyping: (() -> Void)? = nil) {
        guard isTrusted else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Auto-type needs Accessibility permission"
            alert.informativeText = "Strongroom has not been granted Accessibility access, so it will not type anything. You can grant it in System Settings › Privacy & Security › Accessibility, or copy the password instead."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Settings")
            WindowPrivacy.protect(alert.window)
            if alert.runModal() == .alertSecondButtonReturn { openAccessibilitySettings() }
            return
        }
        guard let target, !target.app.isTerminated else {
            let alert = NSAlert()
            alert.messageText = "No target window"
            alert.informativeText = "Switch to the app you want to type into, then use the quick-access shortcut (⌥⌘\\)."
            WindowPrivacy.protect(alert.window)
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Type the password for “\(itemTitle)”?"
        alert.informativeText = """
            Strongroom will type it into:

            App: \(target.appName)
            Window: \(target.windowTitle.map { "“\($0)”" } ?? "(title not available)")

            Only continue if this is the window you expect.
            """
        alert.addButton(withTitle: "Type")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        WindowPrivacy.protect(alert.window)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        beforeTyping?()
        Task { @MainActor in
            target.app.activate()
            // Wait for the target to be frontmost; refuse to type otherwise.
            for _ in 0 ..< 40 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier else {
                NSSound.beep()
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            await typeString(text)
        }
    }

    private static func typeString(_ text: String) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for scalarGroup in text.map({ Array(String($0).utf16) }) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            scalarGroup.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(8))
        }
    }
}
