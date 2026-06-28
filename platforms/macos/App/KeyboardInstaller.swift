#if os(macOS)
    import Foundation
    import Carbon

    /// Installs and registers the embedded Byakaron Keyboard input method on first
    /// launch (and whenever the bundled version changes), following the
    /// mozc/OpenVanilla convention where the GUI app ships its IME inside
    /// `Contents/Library/InputMethods/`.
    ///
    /// Every step is guarded and logged via NSLog; nothing here ever throws to the
    /// UI. If the embedded IME is absent (e.g. a dev build), it logs and returns.
    enum KeyboardInstaller {

        private static let bundleID = "dev.nuhu.labs.Byakaron.Keyboard"

        /// File name of the embedded helper bundle and its executable. Must match the
        /// names produced by scripts/build.sh and recorded in Info-keyboard.plist.
        private static let imeBundleName = "Byakaron Keyboard.app"
        private static let imeExecutableName = "Byakaron Keyboard"

        static func ensureInstalled() {
            let embedded = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/InputMethods/\(imeBundleName)")

            guard FileManager.default.fileExists(atPath: embedded.path) else {
                NSLog(
                    "IMEInstaller: embedded %@ not found at %@ — skipping", imeBundleName,
                    embedded.path)
                return
            }

            let dest = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Input Methods/\(imeBundleName)")

            let embeddedVersion = bundleVersion(at: embedded)
            let installedVersion = bundleVersion(at: dest)

            if installedVersion == nil || installedVersion != embeddedVersion {
                install(from: embedded, to: dest)
            }

            register(at: dest)
            enable()
        }

        // MARK: - Install

        private static func install(from embedded: URL, to dest: URL) {
            NSLog(
                "IMEInstaller: installing IME (embedded=%@ installed=%@)",
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
                NSLog("IMEInstaller: copy failed: %@", error.localizedDescription)
                return
            }

            // Clear the quarantine flag so the IME can be loaded.
            runProcess("/usr/bin/xattr", ["-cr", dest.path])
        }

        // MARK: - Register / enable

        private static func register(at dest: URL) {
            let cfURL = dest as CFURL
            let status = TISRegisterInputSource(cfURL)
            if status != noErr {
                NSLog("IMEInstaller: TISRegisterInputSource failed (status=%d)", Int(status))
            }
        }

        private static func enable() {
            let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
            guard let cfList = TISCreateInputSourceList(filter, true)?.takeRetainedValue(),
                let sources = cfList as? [TISInputSource], !sources.isEmpty
            else {
                NSLog("IMEInstaller: input source %@ not found to enable", bundleID)
                return
            }
            for source in sources {
                let status = TISEnableInputSource(source)
                if status != noErr {
                    NSLog("IMEInstaller: TISEnableInputSource failed (status=%d)", Int(status))
                }
            }
        }

        // MARK: - Helpers

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
                // Swallow — e.g. killall finds no process; not fatal.
                NSLog(
                    "IMEInstaller: %@ %@ failed: %@", launchPath, args.joined(separator: " "),
                    error.localizedDescription)
            }
        }
    }
#endif
