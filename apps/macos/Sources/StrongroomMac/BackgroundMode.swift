import AppKit
import ServiceManagement
import StrongroomKit
import SwiftUI

/// Plain status lines (stderr and the unified log). Never pass secrets,
/// item titles or anything typed by the user.
enum AppLog {
    static func info(_ message: String) {
        NSLog("Strongroom: %@", message)
    }
}

// MARK: menu-bar icon

/// The NSStatusItem: the vault-door template icon (solid when locked) and the
/// Open / Quick Access / Lock Now / Settings / Quit menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let header = NSMenuItem(title: "Strongroom", action: nil, keyEquivalent: "")
    private let lockItem = NSMenuItem(title: "Lock Now", action: nil, keyEquivalent: "")
    private let actions: Actions

    struct Actions {
        let openMain: () -> Void
        let quickAccess: () -> Void
        let lockNow: () -> Void
        let settings: () -> Void
        let menuOpened: () -> Void
    }

    init(actions: Actions) {
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(entry("Open Strongroom", #selector(openMain)))
        let qa = entry("Quick Access", #selector(quickAccess), key: "\\")
        qa.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(qa)
        lockItem.action = #selector(lockNow)
        lockItem.target = self
        lockItem.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
        menu.addItem(lockItem)
        menu.addItem(.separator())
        menu.addItem(entry("Settings…", #selector(settings), key: ","))
        menu.addItem(.separator())
        menu.addItem(entry("Quit Strongroom", #selector(quit), key: "q"))
        item.menu = menu
        update(locked: true)
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    /// Locked: solid door, "Strongroom — Locked", Lock Now disabled.
    func update(locked: Bool) {
        item.button?.image = MenuBarIcon.image(locked: locked)
        item.button?.toolTip = locked ? "Strongroom — Locked" : "Strongroom — Unlocked"
        header.title = locked ? "Strongroom — Locked" : "Strongroom — Unlocked"
        lockItem.isEnabled = !locked
    }

    var headerTitle: String { header.title }

    func menuWillOpen(_ menu: NSMenu) { actions.menuOpened() }

    @objc private func openMain() { actions.openMain() }
    @objc private func quickAccess() { actions.quickAccess() }
    @objc private func lockNow() { actions.lockNow() }
    @objc private func settings() { actions.settings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: Dock icon / activation policy

/// `.regular` (Dock icon, menu bar) while a Strongroom window is open or
/// minimized; `.accessory` (menu-bar icon only) once the last one closes.
@MainActor
enum ActivationPolicy {
    private static var observers: [NSObjectProtocol] = []

    /// Titled, normal-level windows other than panels (the quick-access
    /// overlay, alerts): the main window and the Settings window.
    static func strongroomWindows() -> [NSWindow] {
        NSApp.windows.filter { w in
            !(w is NSPanel) && w.styleMask.contains(.titled) && w.level == .normal
                && (w.isVisible || w.isMiniaturized)
        }
    }

    static var current: String {
        switch NSApp.activationPolicy() {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    static func install() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            })
        }
        // After the close has finished, so the closing window is not counted.
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
        })
    }

    static func update() {
        let want: NSApplication.ActivationPolicy = strongroomWindows().isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        AppLog.info("activation policy -> \(current) (windows=\(strongroomWindows().count))")
    }

    /// Before showing a window: get the Dock icon and menu bar back.
    static func becomeRegular() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            AppLog.info("activation policy -> regular")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: open at login

/// Settings › Open at login, through `SMAppService.mainApp`.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var lastError: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    var statusText: String {
        switch status {
        case .enabled: return "On"
        case .requiresApproval: return "Waiting for approval"
        case .notRegistered: return "Off"
        case .notFound: return "Off (not registered with macOS)"
        @unknown default: return "Unknown"
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    nonisolated static func name(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    func set(_ on: Bool) {
        lastError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = (on ? "Could not turn on Open at login: " : "Could not turn off Open at login: ")
                + error.localizedDescription
            AppLog.info("login item \(on ? "register" : "unregister") failed: \((error as NSError).domain) \((error as NSError).code)")
        }
        refresh()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: lock triggers

/// Feeds system events to the lock coordinator: sleep (before it happens),
/// screen lock, screen saver, fast user switch, logout/shutdown.
@MainActor
final class SystemLockObserver {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var idleTimer: Timer?
    private var activityMonitor: Any?

    init(coordinator: LockCoordinator) {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ event: LockEvent) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak coordinator] _ in
                MainActor.assumeIsolated {
                    let locked = coordinator?.handle(event) ?? false
                    AppLog.info("event \(event.rawValue) -> \(locked ? "locked" : "ignored (setting off)")")
                }
            }
            observers.append((center, token))
        }
        on(ws, NSWorkspace.willSleepNotification, .systemSleep)
        on(ws, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned)
        on(ws, NSWorkspace.willPowerOffNotification, .appTerminating)
        on(dnc, Notification.Name("com.apple.screenIsLocked"), .screenLocked)
        on(dnc, Notification.Name("com.apple.screensaver.didstart"), .screensaverStarted)
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            AppLog.info("did wake")
        }))

        // "Last Strongroom interaction": events delivered to this app only
        // (windows, the overlay); the hotkey and the menu note it separately.
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak coordinator] event in
            MainActor.assumeIsolated { coordinator?.noteActivity() }
            return event
        }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                if coordinator?.checkIdle() == true { AppLog.info("event idleTimeout -> locked") }
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }
}

// MARK: verification hooks

/// Only with STRONGROOM_DEBUG_HOOKS=1 in the environment (smoke tests).
/// Commands arrive as distributed notifications named
/// `app.strongroom.debug` whose object is the command. Every command is
/// harmless (lock, show, close, report state); none unlocks or reveals data.
@MainActor
enum DebugHooks {
    static let name = Notification.Name("app.strongroom.debug")
    private static var token: NSObjectProtocol?

    static func installIfEnabled(_ delegate: AppDelegate) {
        guard ProcessInfo.processInfo.environment["STRONGROOM_DEBUG_HOOKS"] == "1" else { return }
        AppLog.info("debug hooks enabled")
        token = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak delegate] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { delegate?.debugCommand(command) }
        }
    }
}

/// Captures SwiftUI's `openWindow` so AppKit code (menu-bar item, overlay,
/// hotkey) can re-create the main window after it was closed.
struct WindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow
    let store: (OpenWindowAction) -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear { store(openWindow) }
    }
}
