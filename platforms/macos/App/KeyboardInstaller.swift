#if os(macOS)
    import AppKit
    import Carbon

    /// Installs and detects the embedded Byakaron Keyboard input method.
    ///
    /// Two installation paths are supported, and both stay available:
    ///
    ///   1. **Automatic (default, non-sandboxed builds).** `ensureInstalled()` copies
    ///      the embedded IME into `~/Library/Input Methods`, clears quarantine, and
    ///      registers/enables it via the Carbon `TIS…` APIs — the mozc/OpenVanilla
    ///      convention. This is the default while Byakaron ships non-sandboxed.
    ///
    ///   2. **Manual (sandbox-friendly fallback).** `revealKeyboardInFinder()` shows
    ///      the bundled "Byakaron Keyboard.app" in Finder so the user can drag it into
    ///      `~/Library/Input Methods` themselves. Used when the sandbox forbids the
    ///      automatic copy/register, or when the keyboard doesn't show up.
    ///
    /// Every step is guarded and logged via NSLog; nothing here throws to the UI.
    enum KeyboardInstaller {

        /// File name of the embedded helper bundle and its executable. Must match the
        /// names produced by scripts/build.sh and recorded in Info-keyboard.plist.
        static let imeBundleName = "Byakaron Keyboard.app"
        private static let imeExecutableName = "Byakaron Keyboard"

        /// Identifier of the Byakaron input source. Both build systems in this repo
        /// (scripts/build.sh and Byakaron.xcodeproj) now stamp the same id, recorded
        /// in Resources/Info-keyboard.plist as TISInputSourceID / CFBundleIdentifier.
        ///
        /// IMPORTANT: macOS only treats a bundle as a keyboard input source when its
        /// identifier contains the `inputmethod` token (cf. Apple's own ids such as
        /// `com.apple.inputmethod.Tamil`). Dropping it makes the keyboard vanish from
        /// System Settings → Keyboard → Input Sources, so keep it in any rename.
        private static let knownInputSourceIDs: Set<String> = [
            "dev.nuhu.labs.inputmethod.Byakaron"
        ]

        // MARK: - Locations

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

        /// The install destination for the keyboard.
        static var installedKeyboardURL: URL {
            inputMethodsDirectory.appendingPathComponent(imeBundleName)
        }

        /// Whether the keyboard file is present in `~/Library/Input Methods`. Inside a
        /// sandbox we may be unable to read that folder, so a `false` can mean
        /// "couldn't confirm" — prefer `isInputSourceAdded()` to know if it's usable.
        static var isInstalled: Bool {
            FileManager.default.fileExists(atPath: installedKeyboardURL.path)
        }

        // MARK: - Automatic install (default)

        /// Copy (if needed), register, and enable the embedded keyboard. Safe to call
        /// on every launch — it only re-copies when the bundled version changed, and
        /// every step degrades gracefully (e.g. under the sandbox the copy fails and
        /// the user falls back to the manual "Reveal Keyboard" flow).
        static func ensureInstalled() {
            guard let embedded = embeddedKeyboardURL else {
                NSLog("KeyboardInstaller: embedded %@ not found — skipping auto-install", imeBundleName)
                return
            }

            let dest = installedKeyboardURL
            let embeddedVersion = bundleVersion(at: embedded)
            let installedVersion = bundleVersion(at: dest)

            if installedVersion == nil || installedVersion != embeddedVersion {
                install(from: embedded, to: dest)
            }

            register(at: dest)
            enable()
        }

        private static func install(from embedded: URL, to dest: URL) {
            NSLog(
                "KeyboardInstaller: installing IME (embedded=%@ installed=%@)",
                bundleVersion(at: embedded) ?? "nil",
                bundleVersion(at: dest) ?? "nil")

            // Stop any running copy so we can replace it.
            runProcess("/usr/bin/killall", [imeExecutableName])

            let fm = FileManager.default
            try? fm.removeItem(at: dest)

            do {
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fm.copyItem(at: embedded, to: dest)
            } catch {
                // Expected under the sandbox; the manual reveal flow covers this.
                NSLog("KeyboardInstaller: copy failed (%@) — use manual install", error.localizedDescription)
                return
            }

            // Clear the quarantine flag so the IME can be loaded.
            runProcess("/usr/bin/xattr", ["-cr", dest.path])
        }

        private static func register(at dest: URL) {
            guard FileManager.default.fileExists(atPath: dest.path) else { return }
            let status = TISRegisterInputSource(dest as CFURL)
            if status != noErr {
                NSLog("KeyboardInstaller: TISRegisterInputSource failed (status=%d)", Int(status))
            }
        }

        private static func enable() {
            for source in matchingSources(enabledOnly: false) {
                let status = TISEnableInputSource(source)
                if status != noErr {
                    NSLog("KeyboardInstaller: TISEnableInputSource failed (status=%d)", Int(status))
                }
            }
        }

        // MARK: - Manual install (fallback)

        /// Reveal the embedded keyboard in Finder so the user can drag it into
        /// `~/Library/Input Methods`. Finder runs outside our sandbox, so this works
        /// even when the automatic copy can't.
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

        /// Open the `~/Library/Input Methods` destination in Finder. Falls back to
        /// `~/Library` if the folder doesn't exist yet.
        static func openInputMethodsFolder() {
            let fm = FileManager.default
            let dir = inputMethodsDirectory
            // Make sure the destination exists so the drag target is always present.
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = fm.fileExists(atPath: dir.path) ? dir : dir.deletingLastPathComponent()
            NSWorkspace.shared.open(target)
        }

        /// One-click manual install: reveal the bundled keyboard *and* open its
        /// `~/Library/Input Methods` destination so the user can drag it across — the
        /// same "drag the app into the folder" gesture as a .dmg installer, just with
        /// the two windows opened for them. Used for sandboxed builds (or whenever the
        /// automatic copy can't run).
        ///
        /// - Returns: `false` if there's no embedded keyboard to reveal.
        @discardableResult
        static func startManualInstall() -> Bool {
            // Open the destination first so the revealed keyboard ends up frontmost.
            openInputMethodsFolder()
            return revealKeyboardInFinder()
        }

        // MARK: - System Settings

        /// Open System Settings straight to Keyboard → Input Sources, where the user
        /// adds/removes Byakaron with the "+" button. Falls back to the Keyboard pane
        /// (and then System Settings itself) on OS versions that don't accept the
        /// deep-link URL.
        static func openInputSourcesSettings() {
            let urls = [
                // Keyboard settings pane (Ventura+ System Settings).
                "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
                // Last-resort: just open System Settings.
                "x-apple.systempreferences:",
            ]
            for string in urls {
                if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
            }
        }

        // MARK: - Detection

        /// Whether the Byakaron input source is currently added/enabled in the user's
        /// Input Sources (System Settings → Keyboard → Input Sources). This is the
        /// reliable signal for "is the keyboard usable", and works in or out of the
        /// sandbox.
        static func isInputSourceAdded() -> Bool {
            !matchingSources(enabledOnly: true).isEmpty
        }

        // MARK: - Helpers

        /// Byakaron input sources known to the system. `enabledOnly == true` returns
        /// only the ones the user has actually added; `false` returns all installed.
        private static func matchingSources(enabledOnly: Bool) -> [TISInputSource] {
            guard
                let cfList = TISCreateInputSourceList(nil, !enabledOnly)?.takeRetainedValue(),
                let sources = cfList as? [TISInputSource]
            else { return [] }

            return sources.filter { source in
                if let id = property(source, kTISPropertyInputSourceID),
                    knownInputSourceIDs.contains(id) { return true }
                if let bundleID = property(source, kTISPropertyBundleID),
                    knownInputSourceIDs.contains(bundleID) { return true }
                return false
            }
        }

        private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
            guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }

        private static func bundleVersion(at appURL: URL) -> String? {
            let plist = appURL.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any]
            else { return nil }
            return dict["CFBundleVersion"] as? String
        }

        private static func runProcess(_ launchPath: String, _ args: [String]) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                // Swallow — e.g. killall finds no process, or the sandbox blocks it.
                NSLog(
                    "KeyboardInstaller: %@ %@ failed: %@", launchPath, args.joined(separator: " "),
                    error.localizedDescription)
            }
        }
    }
#endif
