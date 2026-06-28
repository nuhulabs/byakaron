import SwiftUI

/// Byakaron — a Bangla typing app for macOS that bundles two things in one place:
/// the phonetic input method (installed and configured from here) and a dedicated
/// Bangla spell-checking editor.
///
/// Everything the user configures lives in this single app: input-method options
/// in the standard Settings window (⌘,), and setup instructions in the Help menu
/// (top-right of the menu bar). The IME itself runs as an embedded background
/// helper and reads its options from the shared settings suite.
///
/// Byakaron is sandboxed, so it can't install the keyboard automatically. The
/// Setup guide instead reveals the embedded "Byakaron Keyboard.app" in Finder and
/// the user drags it into `~/Library/Input Methods` (see `KeyboardInstaller`).
@main
struct ByakaronApp: App {
    @StateObject private var checker = SpellChecker()

    /// Stable id for the Help → Guide window so the menu command can open it.
    static let guideWindowID = "byakaron-guide"

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(checker)
        }
        #if os(macOS)
        .defaultSize(width: 720, height: 560)
        .commands { GuideCommands() }
        #endif

        #if os(macOS)
        // Settings window (⌘,) — input-method options the embedded IME reads.
        Settings {
            SettingsView()
        }

        // Setup & layout guide, opened from the Help menu (top-right menu bar).
        Window("Byakaron Guide", id: Self.guideWindowID) {
            GuideView()
        }
        .defaultSize(width: 560, height: 640)
        .windowResizability(.contentMinSize)
        #endif
    }
}

#if os(macOS)
/// Adds "Byakaron Setup Guide" to the standard Help menu (the rightmost app menu),
/// which is exactly where macOS users expect setup/how-to material.
private struct GuideCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Byakaron Setup Guide") {
                openWindow(id: ByakaronApp.guideWindowID)
            }
            .keyboardShortcut("?", modifiers: .command)

            Divider()

            Link("Byakaron on GitHub",
                 destination: URL(string: "https://github.com/nuhulabs/Byakaron")!)
        }
    }
}
#endif
