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
        // Opened files are handled by the app delegate, not by spawning windows.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About GoAway") {
                    AboutWindowController.shared.show(model: appDelegate.model)
                }
            }
            CommandGroup(after: .appInfo) {
                if appDelegate.model.updates.isAvailable {
                    Button("Check for Updates…") {
                        appDelegate.model.updates.checkForUpdates()
                    }
                    .disabled(!appDelegate.model.updates.canCheck)
                }
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
    private let services = ServicesProvider()
    private var launched = false
    private var launchFiles: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launch finishes so a Services request that launched us is delivered.
        services.model = model
        NSApp.servicesProvider = services
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        BrandAppearance.applyAppIcon()
        if activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        launched = true
        model.updates.start()

        // Opening files (dropped on the icon) must never erase the whole Trash.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let openedFiles = event?.eventClass == AEEventClass(kCoreEventClass)
            && event?.eventID == AEEventID(kAEOpenDocuments)
        if openedFiles || !launchFiles.isEmpty {
            let files = launchFiles
            launchFiles = []
            if files.isEmpty {
                model.waitForRequest()
            } else {
                // Let the window come up before the confirmation alert.
                Task { @MainActor in self.model.eraseSelection(files) }
            }
            return
        }

        // Not default: launched for a Service or similar. Wait for the request.
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefault {
            model.startIfNeeded()
        } else {
            model.waitForRequest()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard launched else {
            launchFiles += files
            return
        }
        model.eraseSelection(files)
    }

    // No window restoration: a restored launch is not a default launch, and
    // would otherwise wait instead of erasing.
    func applicationShouldSaveApplicationState(_ app: NSApplication, coder: NSCoder) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication, coder: NSCoder) -> Bool {
        false
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.prepareToQuit() ? .terminateLater : .terminateNow
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

/// Finder ▸ Services ▸ Erase with GoAway (declared under NSServices in Info.plist).
@MainActor
final class ServicesProvider: NSObject {
    weak var model: AppModel?

    @objc(eraseFiles:userData:error:)
    func eraseFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files were selected."
            return
        }
        model?.eraseSelection(urls)
    }
}
