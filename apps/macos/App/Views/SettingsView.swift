import Combine
import SwiftUI

/// Tabs of the Settings window. The raw values double as the persisted selection
/// key, so other parts of the app (e.g. the launch-time setup check in `MainView`)
/// can deep-link to a specific tab by writing `selectionKey` before opening
/// Settings.
enum SettingsTab: String, CaseIterable {
    case setup, typing, suggestions, dictionary, layout

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

            TypingSettings(model: model)
                .tabItem { Label(tr(BYK_STR_TYPING), systemImage: "keyboard") }
                .tag(SettingsTab.typing.rawValue)

            CandidateSettings(model: model)
                .tabItem { Label(tr(BYK_STR_CANDIDATES), systemImage: "list.bullet.rectangle") }
                .tag(SettingsTab.suggestions.rawValue)

            PersonalDictionarySettings(model: model)
                .tabItem { Label(tr(BYK_STR_PERSONAL_DICTIONARY), systemImage: "character.book.closed") }
                .tag(SettingsTab.dictionary.rawValue)

            LayoutTab()
                .tabItem { Label(tr(BYK_STR_LAYOUT), systemImage: "keyboard.badge.ellipsis") }
                .tag(SettingsTab.layout.rawValue)
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

    @Published var values = ByakaronSettings.Values() {
        didSet {
            guard values != oldValue, !loading, let composer else { return }
            ByakaronSettings.set(values, composer)
        }
    }
    @Published private(set) var userWords: [String] = []
    private var loading = false

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
        loading = true
        values = ByakaronSettings.get(composer)
        userWords = ByakaronSettings.userWords(composer)
        loading = false
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

// MARK: - Typing

private struct TypingSettings: View {
    @ObservedObject var model: KeyboardSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.values.suggestions) {
                    Text(tr(BYK_STR_SUGGESTIONS))
                    Text(tr(BYK_STR_SUGGESTIONS_HINT))
                }
                Toggle(isOn: $model.values.spellingCorrections) {
                    Text(tr(BYK_STR_SPELLING_CORRECTIONS))
                    Text(tr(BYK_STR_SPELLING_CORRECTIONS_HINT))
                }
                Toggle(isOn: $model.values.learnChoices) {
                    Text(tr(BYK_STR_LEARN_CHOICES))
                    Text(tr(BYK_STR_LEARN_CHOICES_HINT))
                }
                Toggle(isOn: $model.values.banglaDigits) {
                    Text(tr(BYK_STR_BANGLA_DIGITS))
                    Text(tr(BYK_STR_BANGLA_DIGITS_HINT))
                }
                Toggle(isOn: $model.values.newlineOnEnter) {
                    Text(tr(BYK_STR_NEWLINE_ON_ENTER))
                    Text(tr(BYK_STR_NEWLINE_ON_ENTER_HINT))
                }
            } header: {
                Text(tr(BYK_STR_TYPING))
            } footer: {
                Text(tr(BYK_STR_TYPING_HINT))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Candidates

private struct CandidateSettings: View {
    @ObservedObject var model: KeyboardSettingsModel

    var body: some View {
        Form {
            Section {
                Picker(tr(BYK_STR_CANDIDATE_ORIENTATION), selection: $model.values.candidateOrientation) {
                    ForEach(ByakaronSettings.Orientation.allCases) { o in
                        Text(o.label).tag(o)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent(tr(BYK_STR_CANDIDATES_PER_PAGE)) {
                    Stepper(
                        "\(model.values.candidatesPerPage)",
                        value: $model.values.candidatesPerPage,
                        in: ByakaronSettings.candidatesPerPageRange)
                }
            } header: {
                Text(tr(BYK_STR_CANDIDATES))
            } footer: {
                Text(tr(BYK_STR_CANDIDATES_HINT))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
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
    TypingSettings(model: KeyboardSettingsModel()).frame(width: 540)
}
#Preview("Suggestions") {
    CandidateSettings(model: KeyboardSettingsModel()).frame(width: 540)
}
#Preview("Dictionary") {
    PersonalDictionarySettings(model: KeyboardSettingsModel()).frame(width: 540)
}
#endif
