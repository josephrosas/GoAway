import AppKit
import SwiftUI

@main
struct GoAwayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WipeRootView()
                .environment(appDelegate.model)
                .tint(GoAwayTheme.accent)
                .preferredColorScheme(appDelegate.model.appearance.colorScheme)
        }
        .defaultSize(width: 420, height: 340)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About GoAway") {
                    AboutWindowController.shared.show(model: appDelegate.model)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Send Feedback…") {
                    appDelegate.model.sendFeedback()
                }
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .tint(GoAwayTheme.accent)
                .preferredColorScheme(appDelegate.model.appearance.colorScheme)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        BrandAppearance.applyAppIcon()
        if activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        model.startIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func activateExistingInstance() -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .filter { $0.processIdentifier != mine }
        guard let other = others.first else { return false }
        other.activate()
        return true
    }
}
