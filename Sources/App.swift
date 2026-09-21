import AppKit
import ServiceManagement
import SwiftUI

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = UsageStore.shared

    init() {
        // `ClaudeUsage --unregister-login-item` removes the Open-at-login registration without the UI (uninstall aid).
        if CommandLine.arguments.contains("--unregister-login-item") {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                print("unregister failed: \(error.localizedDescription)")
            }
            print("open at login enabled: \(SMAppService.mainApp.status == .enabled)")
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopover(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// On first run the menu bar item alone doesn't explain what the app is about to ask for,
    /// so open the welcome window before any Keychain read can surprise anyone.
    /// `--show-welcome` opens it regardless, for anyone who dismissed it and wants it back
    /// without hunting for the ? button.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let forced = CommandLine.arguments.contains("--show-welcome")
        guard forced || !UserDefaults.standard.bool(forKey: WelcomeWindowController.seenKey) else { return }
        WelcomeWindowController.shared.show(store: UsageStore.shared)
    }
}
