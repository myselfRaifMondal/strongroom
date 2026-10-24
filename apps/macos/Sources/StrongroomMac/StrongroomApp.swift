import AppKit
import StrongroomKit
import SwiftUI

@main
struct StrongroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Strongroom", id: "main") {
            RootView()
                .environmentObject(delegate.model)
                .frame(minWidth: 760, minHeight: 480)
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
                Button("Lock Vault") { delegate.model.lock() }
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
            }
            CommandGroup(after: .windowArrangement) {
                Button("Quick Access") { delegate.quickAccess.toggle() }
                    .keyboardShortcut("\\", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var quickAccess = QuickAccessController(model: model)
    private var hotKey: GlobalHotKey?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        WindowPrivacy.install()
        AutoType.startTrackingExternalApps()

        // ⌥⌘\ from anywhere opens the quick-access overlay.
        hotKey = GlobalHotKey(keyCode: GlobalHotKey.kVK_ANSI_Backslash,
                              modifiers: GlobalHotKey.optionCommand) { [weak self] in
            self?.quickAccess.toggle()
        }
        model.hotKeyRegistered = hotKey != nil

        // Lock when the Mac sleeps or the screen locks.
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.lock() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.lock() }
        })

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
        // Keep running so the global hotkey still works.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.lock()
        SecureClipboard.shared.clearNow()
    }
}
