import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Setup-and-help surface for Byakaron, opened from the Help menu (top-right of
/// the menu bar) rather than shown automatically. Two tabs: how to set the
/// keyboard up + how to type, and the full Avro phonetic layout reference.
struct GuideView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case gettingStarted = "Getting Started"
        case layout = "Avro Layout"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .gettingStarted: return "sparkles"
            case .layout: return "keyboard"
            }
        }
    }

    @State private var selection: Tab = .gettingStarted

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases) { tab in
                content(tab)
                    .tabItem { Label(tab.rawValue, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    @ViewBuilder
    private func content(_ tab: Tab) -> some View {
        switch tab {
        case .gettingStarted: GettingStartedTab()
        case .layout: LayoutTab()
        }
    }
}

// MARK: - Getting Started Tab

struct GettingStartedTab: View {
    @State private var updateStatus: UpdateChecker.Status = .idle

    private let setupSteps: [(String, String?)] = [
        ("Click “Reveal Keyboard” below to show the keyboard in Finder", "Byakaron Keyboard.app, bundled inside the app"),
        ("Drag “Byakaron Keyboard.app” into the Input Methods folder", "~/Library/Input Methods — use “Open Folder” below"),
        ("Open System Settings → Keyboard → Input Sources", nil),
        ("Click  +  → search “Byakaron” → select Byakaron → Add", nil),
        ("Use the Globe key or Ctrl+Space to switch input methods", nil),
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                groupCard(title: "Setup", icon: "checklist") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(setupSteps.enumerated()), id: \.offset) { index, step in
                            stepRow(number: index + 1, text: step.0, note: step.1)
                        }
                        Divider().padding(.vertical, 2)
                        installActions
                    }
                }

                groupCard(title: "How to Type", icon: "keyboard") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(typingTips.enumerated()), id: \.offset) { _, tip in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(tip.0)
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 130, alignment: .leading)
                                Text(tip.1)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }

                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Byakaron")
                .font(.system(size: 26, weight: .bold))
        }
    }

    /// Buttons that drive the manual install: reveal the bundled keyboard and open
    /// its destination folder. Byakaron is sandboxed, so it can't copy the keyboard
    /// itself — Finder (a separate process) does the move when the user drags it.
    private var installActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if !KeyboardInstaller.revealKeyboardInFinder() {
                        Self.presentKeyboardMissingAlert()
                    }
                } label: {
                    Label("Reveal Keyboard", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .help("Show “Byakaron Keyboard.app” in Finder so you can drag it into place")

                Button {
                    KeyboardInstaller.openInputMethodsFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open ~/Library/Input Methods, where the keyboard belongs")
            }

            Text("Drag “Byakaron Keyboard.app” from the revealed window into Input Methods, then add it under System Settings → Keyboard → Input Sources.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 13))
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Developed by **Nurul Huda (Apon)**")
                        .font(.system(size: 12))
                    HStack(spacing: 6) {
                        Link("github.com/nuhulabs", destination: URL(string: "https://github.com/nuhulabs")!)
                        Text("·").foregroundStyle(.secondary)
                        Link("nuhulabs.github.io", destination: URL(string: "https://nuhulabs.github.io")!)
                    }
                    .font(.system(size: 11))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Button(action: checkForUpdate) {
                        if case .checking = updateStatus {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Check for Update")
                        }
                    }
                    .disabled(updateStatus == .checking)
                    updateStatusLabel
                }
            }

            Text("Powered by OpenBangla’s riti engine. Built for the Bengali community on macOS.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch updateStatus {
        case .idle, .checking:
            EmptyView()
        case .upToDate(let version):
            Text("You’re up to date (\(version))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .available(let version, _):
            Text("Update \(version) available")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
        case .failed(let message):
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func groupCard<Content: View>(
        title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        alert.informativeText = "Byakaron \(version) is available. You are currently running \(current)."
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
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
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
                    let html = json["html_url"] as? String
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
#Preview("Guide") {
    GuideView()
        .frame(width: 560, height: 640)
}

#Preview("Getting Started") {
    GettingStartedTab()
        .frame(width: 560, height: 640)
}
#endif
