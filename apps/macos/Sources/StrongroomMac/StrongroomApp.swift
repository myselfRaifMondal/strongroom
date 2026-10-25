import AppKit
import Combine
import ServiceManagement
import StrongroomKit
import SwiftUI

/// The app's scenes. Started from `StrongroomMacMain/main.swift`.
public struct StrongroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {}

    public var body: some Scene {
        Window("Strongroom", id: "main") {
            RootView()
                .environmentObject(delegate.model)
                .frame(minWidth: 760, minHeight: 480)
                .background(WindowOpenerCapture { [weak delegate] in delegate?.openWindowAction = $0 })
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Item") { delegate.model.requestNewItem() }
                    .keyboardShortcut("n")
                    .disabled(!delegate.model.isUnlocked)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Import VTF…") { delegate.model.beginImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!delegate.model.isUnlocked)
                Button("Import with This Mac's Key…") { Task { await delegate.model.importWithThisMacsKey() } }
                    .disabled(!delegate.model.isUnlocked)
                Button("Import from Another Password Manager (CSV)…") { delegate.model.sheet = .csvImport }
                    .disabled(!delegate.model.isUnlocked)
                Button("Export VTF…") { delegate.model.beginExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!delegate.model.isUnlocked)
                Button("Back Up Vault…") { Task { await delegate.model.backup() } }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!delegate.model.isUnlocked)
                Button("Devices and Pairing…") { delegate.model.sheet = .devices }
                    .disabled(!delegate.model.isUnlocked)
                Divider()
                Button("New Folder…") { delegate.model.sheet = .folderName(.create(parent: delegate.model.currentFolder)) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!delegate.model.isUnlocked)
                Divider()
                Button("Lock Vault") { delegate.model.requestLock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!delegate.model.isUnlocked)
            }
            CommandMenu("Vault") {
                Button("All Items") { delegate.model.selectFolder([]) }
                    .keyboardShortcut("1", modifiers: [.command])
                    .disabled(!delegate.model.isUnlocked)
                Button("Favourites") { delegate.model.sidebar = .favourites }
                    .keyboardShortcut("2", modifiers: [.command])
                    .disabled(!delegate.model.isUnlocked)
                Button("Password Health") { delegate.model.sidebar = .health }
                    .keyboardShortcut("3", modifiers: [.command])
                    .disabled(!delegate.model.isUnlocked)
                Button("Trash") { delegate.model.sidebar = .trash }
                    .keyboardShortcut("4", modifiers: [.command])
                    .disabled(!delegate.model.isUnlocked)
                Button("Security Ranking") { delegate.model.sidebar = .ranking }
                    .keyboardShortcut("5", modifiers: [.command])
                    .disabled(!delegate.model.isUnlocked)
                Divider()
                Button("Organize by Service…") { delegate.model.requestOrganize() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!delegate.model.isUnlocked)
                Button("Undo Organize") { delegate.model.undoOrganize() }
                    .disabled(!delegate.model.isUnlocked || !delegate.model.canUndoOrganize)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Quick Access") { delegate.quickAccess.toggle() }
                    .keyboardShortcut("\\", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(delegate.model)
                .background(WindowOpenerCapture { [weak delegate] in delegate?.openWindowAction = $0 })
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var quickAccess = QuickAccessController(model: model)
    /// SwiftUI's openWindow, captured from the first window that appeared.
    var openWindowAction: OpenWindowAction?
    /// Owned for the whole process lifetime, independent of any window, so
    /// ⌥⌘\ works while the app runs only in the menu bar.
    private var hotKey: GlobalHotKey?
    private var statusBar: StatusBarController?
    private var lockCoordinator: LockCoordinator?
    private var lockObserver: SystemLockObserver?
    private var phaseObserver: Any?
    private var settingsObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Verification only: can this (ad-hoc signed) bundle post notifications?
        if ProcessInfo.processInfo.environment["STRONGROOM_NOTIFICATION_PROBE"] == "1" {
            Task { await ReminderScheduler.runProbe() }
            return
        }
        NSApp.setActivationPolicy(.regular)
        WindowPrivacy.install()
        AutoType.startTrackingExternalApps()
        ActivationPolicy.install()

        // Locking: every trigger goes through one coordinator.
        let coordinator = LockCoordinator(settings: model.lockSettings)
        coordinator.session = model
        coordinator.onLock = { [weak self] event in self?.didLock(event) }
        lockCoordinator = coordinator
        lockObserver = SystemLockObserver(coordinator: coordinator)
        model.lockRequestHandler = { [weak self] in self?.lockCoordinator?.handle(.manual) }
        model.didUnlockHandler = { [weak self] in self?.lockCoordinator?.noteActivity() }
        settingsObserver = model.$lockSettings.dropFirst().sink { [weak self] s in
            s.save()
            self?.lockCoordinator?.update(s)
        }

        quickAccess.openMainWindowHandler = { [weak self] in self?.openMainWindow() }

        // ⌥⌘\ from anywhere opens the quick-access overlay.
        hotKey = GlobalHotKey(keyCode: GlobalHotKey.kVK_ANSI_Backslash,
                              modifiers: GlobalHotKey.optionCommand) { [weak self] in
            self?.lockCoordinator?.noteActivity()
            self?.quickAccess.toggle()
        }
        model.hotKeyRegistered = hotKey != nil
        AppLog.info(hotKey != nil ? "hotkey registered (option-command-backslash) for the process lifetime"
                                  : "hotkey registration failed")

        statusBar = StatusBarController(actions: .init(
            openMain: { [weak self] in self?.openMainWindow() },
            quickAccess: { [weak self] in self?.quickAccess.show() },
            lockNow: { [weak self] in self?.lockCoordinator?.handle(.manual) },
            settings: { [weak self] in self?.openSettings() },
            menuOpened: { [weak self] in self?.lockCoordinator?.noteActivity() }))
        phaseObserver = model.$phase.sink { [weak self] phase in
            self?.statusBar?.update(locked: phase != .unlocked)
        }

        DebugHooks.installIfEnabled(self)
        NSApp.activate(ignoringOtherApps: true)

        // CI / verification: also open the quick-access overlay so its window
        // can be checked for capture exclusion.
        if ProcessInfo.processInfo.environment["STRONGROOM_SMOKE_OVERLAY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.quickAccess.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar so the global hotkey still works.
        false
    }

    /// Dock icon clicked (or app re-opened from Finder) with no window open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let lockCoordinator {
            lockCoordinator.handle(.appTerminating)
        } else {
            model.lock()
            SecureClipboard.shared.clearNow()
        }
    }

    // MARK: lock clean-up

    /// Runs after the vault object is dropped and before the clipboard is
    /// cleared: close the overlay, any modal alert or file panel, and stop a
    /// pending auto-type.
    private func didLock(_ event: LockEvent) {
        AutoType.lockGeneration += 1
        quickAccess.hide()
        quickAccess.unlockError = nil
        // Alerts and file panels run modally (runModal); SwiftUI sheets close
        // through the model (lock() clears them) and their views' state.
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        statusBar?.update(locked: true)
        AppLog.info("locked (\(event.rawValue))")
    }

    // MARK: windows

    func openMainWindow() {
        quickAccess.hide()
        model.lockedAutomatically = false
        ActivationPolicy.becomeRegular()
        if let open = openWindowAction {
            open(id: "main")
        } else if let w = mainWindow() {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            showViaWindowMenu()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            ActivationPolicy.update()
            if self.model.phase == .locked { self.model.touchIDPromptRequest += 1 }
        }
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// SwiftUI lists the `Window` scene in the Window menu; selecting it
    /// re-creates the window when no openWindow action was captured yet.
    private func showViaWindowMenu() {
        guard let menu = NSApp.windowsMenu,
              let idx = menu.items.firstIndex(where: { $0.title == "Strongroom" }) else { return }
        menu.performActionForItem(at: idx)
    }

    func openSettings() {
        ActivationPolicy.becomeRegular()
        // The app menu's "Settings…" item (⌘,) opens the SwiftUI Settings scene.
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let idx = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            appMenu.performActionForItem(at: idx)
        }
        DispatchQueue.main.async { ActivationPolicy.update() }
    }

    // MARK: verification

    /// STRONGROOM_DEBUG_HOOKS=1 only (see DebugHooks). Logs state, never data.
    func debugCommand(_ command: String) {
        AppLog.info("debug command: \(command)")
        switch command {
        case "simulate-sleep":
            // Real sleep cannot be triggered safely; this is the same path the
            // willSleep observer takes.
            lockCoordinator?.handle(.systemSleep)
        case "show-overlay": quickAccess.show()
        case "hide-overlay": quickAccess.hide()
        case "open-main": openMainWindow()
        case "open-settings": openSettings()
        case "close-windows":
            for w in ActivationPolicy.strongroomWindows() { w.performClose(nil) }
        case "state": break
        case "quit": NSApp.terminate(nil); return
        default: return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.logState() }
    }

    func logState() {
        let phase: String
        switch model.phase {
        case .needsVault: phase = "needsVault"
        case .showSecretKey: phase = "showSecretKey"
        case .locked: phase = "locked"
        case .unlocked: phase = "unlocked"
        case .fatal: phase = "fatal"
        }
        let windows = ActivationPolicy.strongroomWindows().map {
            "\($0.identifier?.rawValue ?? "?") \(Int($0.frame.width))x\(Int($0.frame.height))\($0.isKeyWindow ? " key" : "")"
        }
        let overlaySharing = NSApp.windows.first { $0 is QuickAccessPanel }.map { $0.sharingType == .none ? "none" : "readable" } ?? "n/a"
        AppLog.info("state phase=\(phase) vaultInMemory=\(model.isSessionUnlocked) policy=\(ActivationPolicy.current) "
            + "windows=\(windows) overlay=\(quickAccess.isVisible ? "visible" : "hidden") overlayMode=\(quickAccess.modeDescription) "
            + "overlaySharing=\(overlaySharing) hotkey=\(hotKey != nil ? "registered" : "missing") "
            + "menu=\"\(statusBar?.headerTitle ?? "-")\" lockOnScreenLock=\(model.lockSettings.lockOnScreenLock) "
            + "idleLock=\(model.lockSettings.idleLock.rawValue)s loginItem=\(LoginItem.name(SMAppService.mainApp.status))")
    }
}

