import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

// MARK: - Getting Started Tab

/// The Setup tab shown inside the Settings window: keyboard status, how to enable
/// it, a manual install fallback, and a typing cheat-sheet. Version, updates and
/// the developer are in Byakaron › About Byakaron and the Updates tab.
struct GettingStartedTab: View {
    @State private var keyboardAdded = KeyboardInstaller.isInputSourceAdded()

    private let setupSteps: [(String, String?)] = [
        (
            "Open System Settings → Keyboard → Input Sources",
            "Byakaron installs the keyboard automatically"
        ),
        ("Click  +  → choose Bangla → select Byakaron → Add", nil),
        ("Use the Globe key or Ctrl+Space to switch to Byakaron", nil),
    ]

    private let typingTips: [(String, String)] = [
        ("Type phonetically", "e.g.  ami → আমি,   bangla → বাংলা"),
        ("Space", "commits the top suggestion"),
        ("1–9", "selects a specific candidate from the list"),
        ("Backspace", "deletes the last character"),
        ("Escape", "cancels current input"),
        ("Arrow keys ↑↓", "navigate through candidates"),
    ]

    var body: some View {
        Form {
            statusSection

            Section("Set Up") {
                ForEach(Array(setupSteps.enumerated()), id: \.offset) { index, step in
                    stepRow(number: index + 1, text: step.0, note: step.1)
                }
            }

            Section {
                Button {
                    KeyboardInstaller.openInputSourcesSettings()
                } label: {
                    Label("Open Input Sources", systemImage: "gearshape")
                }
                .help("Open System Settings → Keyboard → Input Sources to add Byakaron")

                Button {
                    if !KeyboardInstaller.startManualInstall() {
                        Self.presentKeyboardMissingAlert()
                    }
                } label: {
                    Label("Install Manually…", systemImage: "square.and.arrow.down.on.square")
                }
                .help(
                    "Open both “Byakaron Keyboard.app” and the Input Methods folder so you can drag it in"
                )
            } footer: {
                Text(
                    "If the keyboard isn’t listed above, install it by hand: drag “Byakaron Keyboard.app” into your Input Methods folder, then add it under Input Sources."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Section("How to Type") {
                ForEach(Array(typingTips.enumerated()), id: \.offset) { _, tip in
                    LabeledContent(tip.0) {
                        Text(tip.1).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { keyboardAdded = KeyboardInstaller.isInputSourceAdded() }
    }

    /// Live status of the Byakaron input source so the user knows whether there's
    /// anything left to do. Refreshable, since adding the source happens outside the
    /// app in System Settings.
    private var statusSection: some View {
        let tint: Color = keyboardAdded ? .green : .orange
        return Section {
            HStack(spacing: 12) {
                Image(
                    systemName: keyboardAdded
                        ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.title2)
                .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(keyboardAdded ? "Keyboard is added" : "Keyboard isn’t added yet")
                        .font(.headline)
                    Text(
                        keyboardAdded
                            ? "Press the Globe key or Ctrl+Space to switch to Byakaron."
                            : "Follow the steps below to add Byakaron in System Settings."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("Re-check") { keyboardAdded = KeyboardInstaller.isInputSourceAdded() }
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    private static func presentKeyboardMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Not Found"
        alert.informativeText =
            "This build of Byakaron doesn’t include the embedded keyboard. "
            + "Reinstall the app from a release build to set up the keyboard."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func stepRow(number: Int, text: String, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
    #Preview("Getting Started") {
        GettingStartedTab()
            .frame(width: 560, height: 640)
    }
#endif
