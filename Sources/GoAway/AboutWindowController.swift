import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()

    private var window: NSWindow?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        if window == nil {
            let root = AboutView()
                .environment(model)
                .tint(GoAwayTheme.accent)

            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "About GoAway"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 420, height: 320))
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
