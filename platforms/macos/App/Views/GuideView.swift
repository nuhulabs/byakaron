import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

// MARK: - Getting Started Tab

/// The Setup tab shown inside the Settings window: keyboard status, how to enable
/// it, a manual install fallback, and a typing cheat-sheet.
struct GettingStartedTab: View {
    @State private var updateStatus: UpdateChecker.Status = .idle
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

            footer
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

    private var footer: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    updateStatusLabel
                    Button(action: checkForUpdate) {
                        if case .checking = updateStatus {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Check for Update")
                        }
                    }
                    .disabled(updateStatus == .checking)
                }
            } label: {
                Text("Version")
                Text(appVersion)
            }
        } header: {
            Text("About")
        } footer: {
            HStack(spacing: 6) {
                Text("Developed by Nurul Huda (Apon)")
                Spacer(minLength: 0)
                Link("GitHub", destination: URL(string: "https://github.com/nuhulabs")!)
                Text("·").foregroundStyle(.secondary)
                Link("Website", destination: URL(string: "https://nuhulabs.github.io")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch updateStatus {
        case .idle, .checking:
            EmptyView()
        case .upToDate:
            Text("Up to date")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available(let version, _):
            Text("Update \(version) available")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private func checkForUpdate() {
        updateStatus = .checking
        UpdateChecker.check { status in
            self.updateStatus = status
            if case .available(let version, let url) = status {
                Self.presentUpdateAlert(version: version, url: url)
            }
        }
    }

    private static func presentUpdateAlert(version: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        let current =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        alert.informativeText =
            "Byakaron \(version) is available. You are currently running \(current)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Update Checker

enum UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String, URL)
        case failed(String)
    }

    static func check(completion: @escaping (Status) -> Void) {
        let currentVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let url = URL(string: "https://api.github.com/repos/nuhulabs/Byakaron/releases/latest")!

        var request = URLRequest(url: url)
        request.setValue("Byakaron/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if error != nil {
                    completion(.failed("Could not check for updates."))
                    return
                }
                guard let data = data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tagName = json["tag_name"] as? String
                else {
                    completion(.failed("Could not read release info."))
                    return
                }

                let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                if isVersion(latest, newerThan: currentVersion) {
                    let html =
                        json["html_url"] as? String
                        ?? "https://github.com/nuhulabs/Byakaron/releases/latest"
                    completion(.available(latest, URL(string: html)!))
                } else {
                    completion(.upToDate(currentVersion))
                }
            }
        }.resume()
    }

    private static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let aVal = i < aParts.count ? aParts[i] : 0
            let bVal = i < bParts.count ? bParts[i] : 0
            if aVal > bVal { return true }
            if aVal < bVal { return false }
        }
        return false
    }
}

#if DEBUG
    #Preview("Getting Started") {
        GettingStartedTab()
            .frame(width: 560, height: 640)
    }
#endif
