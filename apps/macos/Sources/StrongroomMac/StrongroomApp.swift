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
                Button("Export VTF…") { delegate.model.beginExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!delegate.model.isUnlocked)
                Divider()
                Button("Lock Vault") { delegate.model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
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
