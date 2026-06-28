import AppKit

/// Application lifecycle for the Byakaron input method helper.
///
/// This is an InputMethodKit server (see `main.swift`), so AppKit's
/// `NSApplicationDelegate` is required — there is no SwiftUI `App` lifecycle for
/// an IME. Settings and the setup guide now live in the main Byakaron app, so the
/// helper owns no windows of its own; its only UI affordance is opening the main
/// app when the user reopens the helper (e.g. from its menu-bar item).
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Bundle identifier of the SwiftUI main app that hosts Settings and the guide.
    private let mainAppBundleID = "dev.nuhu.byakaron.spell"

    /// Called when the user clicks/reopens the helper while it is already running.
    /// Route them to the main app, which is where everything configurable lives.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainApp()
        return true
    }

    /// Launch (or activate) the main Byakaron app by bundle identifier.
    private func openMainApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainAppBundleID) else {
            NSLog("Byakaron IME: main app (%@) not found to open", mainAppBundleID)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
