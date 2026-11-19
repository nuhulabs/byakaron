import Combine
import SwiftUI

/// Tabs of the Settings window. The raw values double as the persisted selection
/// key, so other parts of the app (e.g. the launch-time setup check in `MainView`)
/// can deep-link to a specific tab by writing `selectionKey` before opening
/// Settings.
enum SettingsTab: String, CaseIterable {
    case setup, typing, suggestions, dictionary, layout, updates

    /// UserDefaults key (in the shared suite) backing the selected tab.
    static let selectionKey = "ByakaronSettingsTab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.selectionKey, store: ByakaronSettings.defaults)
    private var selection = SettingsTab.setup.rawValue

    @StateObject private var model = KeyboardSettingsModel()

    var body: some View {
        TabView(selection: $selection) {
            GettingStartedTab()
                .tabItem { Label(tr(BYK_STR_SETUP), systemImage: "sparkles") }
                .tag(SettingsTab.setup.rawValue)

            ManifestSettings(model: model, section: "typing")
                .tabItem { Label(tr(BYK_STR_TYPING), systemImage: "keyboard") }
                .tag(SettingsTab.typing.rawValue)

            ManifestSettings(model: model, section: "candidates")
                .tabItem { Label(tr(BYK_STR_CANDIDATES), systemImage: "list.bullet.rectangle") }
                .tag(SettingsTab.suggestions.rawValue)

            PersonalDictionarySettings(model: model)
                .tabItem { Label(tr(BYK_STR_PERSONAL_DICTIONARY), systemImage: "character.book.closed") }
                .tag(SettingsTab.dictionary.rawValue)

            LayoutTab()
                .tabItem { Label(tr(BYK_STR_LAYOUT), systemImage: "keyboard.badge.ellipsis") }
                .tag(SettingsTab.layout.rawValue)

            UpdatesTab(model: model)
                .tabItem { Label(tr(BYK_STR_UPDATES), systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates.rawValue)
        }
        .frame(width: 580, height: 620)
        .onAppear {
            // A tab removed since it was last selected.
            if SettingsTab(rawValue: selection) == nil { selection = SettingsTab.setup.rawValue }
            model.reload()
        }
    }
}

// MARK: - Model

/// The keyboard's shared settings and personal dictionary, through the app's own
/// composer on the keyboard's data directory (no Byakaron.db: it never types). The
/// running keyboard picks up what is saved here at its next word.
final class KeyboardSettingsModel: ObservableObject {
    private let composer: OpaquePointer?

    /// Each manifest field's value by key (see `ByakaronSettings.value`).
    @Published private(set) var values: [String: Int] = [:]
    @Published private(set) var userWords: [String] = []

    init() {
        composer = ByakaronSettings.openComposer()
        reload()
    }

    deinit {
        if let composer { byakaron_composer_destroy(composer) }
    }

    /// Re-read what is on disk (another process may have changed it).
    func reload() {
        guard let composer else { return }
        var fresh: [String: Int] = [:]
        for field in SettingsManifest.fields {
            fresh[field.key] = ByakaronSettings.value(field.key, composer)
        }
        values = fresh
        userWords = ByakaronSettings.userWords(composer)
    }

    func binding(_ key: String) -> Binding<Int> {
        Binding(
            get: { self.values[key] ?? 0 },
            set: { value in
                guard let composer = self.composer, value != self.values[key] else { return }
                ByakaronSettings.setValue(key, value, composer)
                self.values[key] = ByakaronSettings.value(key, composer) ?? value
            })
    }

    func toggle(_ key: String) -> Binding<Bool> {
        let number = binding(key)
        return Binding(get: { number.wrappedValue != 0 }, set: { number.wrappedValue = $0 ? 1 : 0 })
    }

    /// Add a word; false if it was already there or is not a word.
    @discardableResult
    func addWord(_ word: String) -> Bool {
        guard let composer else { return false }
        let added = byakaron_userdict_add(composer, word) == 1
        userWords = ByakaronSettings.userWords(composer)
        return added
    }

    func removeWord(_ word: String) {
        guard let composer else { return }
        _ = byakaron_userdict_remove(composer, word)
        userWords = ByakaronSettings.userWords(composer)
    }
}

// MARK: - Manifest sections

/// One section of the shared manifest (Typing, Suggestion list): a control per
/// field, its title and hint as every Byakaron app shows them.
private struct ManifestSettings<Extra: View>: View {
    @ObservedObject var model: KeyboardSettingsModel
    let section: String
    /// More sections under the manifest's (Updates' status and Check Now).
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Form {
            if let section = SettingsManifest.section(section) {
                Section {
                    ForEach(SettingsManifest.fields(in: section)) { field in
                        control(field)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let hint = section.hint {
                        Text(hint).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            extra()
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func control(_ field: SettingsManifest.Field) -> some View {
        switch field.control {
        case .toggle:
            Toggle(isOn: model.toggle(field.key)) {
                Text(field.title)
                if let hint = field.hint { Text(hint) }
            }
        case .choice(let options):
            Picker(selection: model.binding(field.key)) {
                ForEach(options.indices, id: \.self) { i in Text(options[i]).tag(i) }
            } label: {
                Text(field.title)
                if let hint = field.hint { Text(hint) }
            }
            .pickerStyle(.segmented)
        case .number(let range):
            LabeledContent {
                Stepper("\(model.values[field.key] ?? range.lowerBound)", value: model.binding(field.key), in: range)
            } label: {
                Text(field.title)
                if let hint = field.hint { Text(hint) }
            }
        }
    }
}

extension ManifestSettings where Extra == EmptyView {
    init(model: KeyboardSettingsModel, section: String) {
        self.init(model: model, section: section) { EmptyView() }
    }
}

// MARK: - Updates

/// The shared Updates settings (check for updates, release channel), then
/// where the updater stands and Check Now.
private struct UpdatesTab: View {
    @ObservedObject var model: KeyboardSettingsModel
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        ManifestSettings(model: model, section: "updates") {
            Section {
                LabeledContent {
                    HStack {
                        if updater.state == .checking || isDownloading { ProgressView().controlSize(.small) }
                        if case .ready = updater.state {
                            Button("Restart to Update") { updater.restartAndInstall() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Check Now") { Task { await updater.check(announce: false) } }
                                .disabled(updater.state == .checking || isDownloading)
                        }
                    }
                } label: {
                    Text("Byakaron \(updater.currentVersion)")
                    Text(status)
                }
            }
        }
        .onChange(of: model.values["update_channel"]) { old, new in
            if old != nil, old != new { updater.channelChanged() }
        }
    }

    private var isDownloading: Bool {
        if case .downloading = updater.state { return true }
        return false
    }

    private var status: String {
        switch updater.state {
        case .idle:
            if let last = updater.lastChecked {
                return "Last checked \(last.formatted(.relative(presentation: .named)))."
            }
            return updater.isRelease ? "Not checked yet." : "A local build: checks only when asked."
        case .checking: return "Checking…"
        case .upToDate: return "This is the newest version on this channel."
        case .downloading(let version): return "Downloading Byakaron \(version)…"
        case .ready(let version): return "Byakaron \(version) is ready. Restart Byakaron to finish."
        case .failed(let message): return message
        }
    }
}

// MARK: - Personal dictionary

private struct PersonalDictionarySettings: View {
    @ObservedObject var model: KeyboardSettingsModel
    @State private var newWord = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(tr(BYK_STR_ADD_WORD), text: $newWord)
                        .onSubmit(add)
                    Button(tr(BYK_STR_ADD), action: add)
                        .disabled(trimmed.isEmpty)
                }
            } footer: {
                Text(tr(BYK_STR_PERSONAL_DICTIONARY_HINT))
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section("Words") {
                if model.userWords.isEmpty {
                    Text(tr(BYK_STR_NO_WORDS)).foregroundStyle(.secondary)
                }
                ForEach(model.userWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            model.removeWord(word)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("\(tr(BYK_STR_REMOVE)) \(word)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var trimmed: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        model.addWord(trimmed)
        newWord = ""
    }
}

#if DEBUG
#Preview("Setup") {
    GettingStartedTab().frame(width: 540)
}
#Preview("Typing") {
    ManifestSettings(model: KeyboardSettingsModel(), section: "typing").frame(width: 540)
}
#Preview("Suggestions") {
    ManifestSettings(model: KeyboardSettingsModel(), section: "candidates").frame(width: 540)
}
#Preview("Dictionary") {
    PersonalDictionarySettings(model: KeyboardSettingsModel()).frame(width: 540)
}
#endif
