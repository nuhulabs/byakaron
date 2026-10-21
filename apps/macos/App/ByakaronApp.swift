import SwiftUI

/// Byakaron — a Bangla typing app for macOS that bundles two things in one place:
/// the phonetic input method (installed and configured from here) and a dedicated
/// Bangla spell-checking editor.
///
/// Everything the user configures lives in the Settings window (⌘,): the Setup tab
/// walks through enabling the keyboard, alongside the input-method options the
/// embedded IME reads from the shared settings suite.
///
/// By default Byakaron ships non-sandboxed and installs the keyboard automatically
/// on launch (`KeyboardInstaller.ensureInstalled`). A sandboxed build instead uses
/// the Setup tab's "Reveal Keyboard" flow, where the user drags the embedded
/// "Byakaron Keyboard.app" into `~/Library/Input Methods`.
@main
struct ByakaronApp: App {
    @StateObject private var checker = SpellChecker()

    init() {
        #if os(macOS)
        KeyboardInstaller.ensureInstalled()
        #endif
    }

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
        // Settings window (⌘,) — Setup guide + input-method options.
        Settings {
            SettingsView()
        }
        #endif
    }
}

#if os(macOS)
/// Points the standard Help menu (the rightmost app menu) at the Setup tab, which
/// now lives in Settings — exactly where macOS users expect setup/how-to material.
private struct GuideCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            SettingsLink {
                Text("Byakaron Setup Guide")
            }
            .keyboardShortcut("?", modifiers: .command)

            Divider()

            Link("Byakaron on GitHub",
                 destination: URL(string: "https://github.com/nuhulabs/Byakaron")!)
        }
    }
}
#endif
