#if os(macOS)
    import AppKit

    /// Locates the embedded Byakaron Keyboard input method and helps the user put
    /// it where macOS can load it.
    ///
    /// Byakaron now ships sandboxed, so it can no longer copy itself into
    /// `~/Library/Input Methods`, clear quarantine, or register an input source on
    /// the user's behalf — the sandbox forbids all of that. Instead we follow the
    /// well-worn pattern for installing a privileged component: point the user at the
    /// keyboard bundled inside the app and let them drag it into place.
    ///
    /// The embedded keyboard lives at:
    ///
    ///     Byakaron.app/Contents/Library/InputMethods/Byakaron Keyboard.app
    ///
    /// and needs to end up in `~/Library/Input Methods`.
    enum KeyboardInstaller {

        /// File name of the embedded helper bundle. Must match the name produced by
        /// scripts/build.sh and recorded in Info-keyboard.plist.
        static let imeBundleName = "Byakaron Keyboard.app"

        /// The keyboard bundled inside this app, or `nil` for a dev build that
        /// doesn't embed it.
        static var embeddedKeyboardURL: URL? {
            let url = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/InputMethods/\(imeBundleName)")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        /// Where the keyboard has to live for macOS to load it.
        static var inputMethodsDirectory: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Input Methods", isDirectory: true)
        }

        /// The destination the user should drag the keyboard to.
        static var installedKeyboardURL: URL {
            inputMethodsDirectory.appendingPathComponent(imeBundleName)
        }

        /// Best-effort check for whether the keyboard is already in place.
        ///
        /// Inside the sandbox we generally can't read `~/Library/Input Methods`, so
        /// `false` here means "couldn't confirm", not necessarily "missing". Treat it
        /// as a soft hint, never as a hard gate.
        static var isInstalled: Bool {
            FileManager.default.fileExists(atPath: installedKeyboardURL.path)
        }

        /// Reveal the embedded keyboard in Finder so the user can drag it into
        /// `~/Library/Input Methods`. Hands off to Finder, which runs outside our
        /// sandbox, so this works even though we can't touch that folder ourselves.
        ///
        /// - Returns: `false` if there's no embedded keyboard to reveal.
        @discardableResult
        static func revealKeyboardInFinder() -> Bool {
            guard let url = embeddedKeyboardURL else {
                NSLog("KeyboardInstaller: embedded %@ not found — nothing to reveal", imeBundleName)
                return false
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }

        /// Open the `~/Library/Input Methods` destination in Finder so the user has a
        /// window to drop the keyboard into. Falls back to `~/Library` if the folder
        /// doesn't exist yet (macOS creates Input Methods on first install).
        static func openInputMethodsFolder() {
            let fm = FileManager.default
            let dir = inputMethodsDirectory
            let target = fm.fileExists(atPath: dir.path) ? dir : dir.deletingLastPathComponent()
            NSWorkspace.shared.open(target)
        }
    }
#endif
