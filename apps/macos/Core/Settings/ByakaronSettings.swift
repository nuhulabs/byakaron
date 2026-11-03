import Foundation

/// Where Byakaron keeps the user's data, compiled into BOTH the SwiftUI app and the
/// IME helper. Pure Foundation — no AppKit and no IMKit dependency.
///
/// The keyboard's behaviour and its settings live in the Zig composer
/// (src/Composer.zig, settings in src/Composer/Settings.zig). Each process opens
/// its own composer on the same data directory —
/// `~/Library/Application Support/Byakaron` (settings.json, selections.json,
/// user-words.txt) — and a running keyboard picks up changes the app saved at its
/// next word, so no cross-process notification is needed.
enum ByakaronSettings {

    /// Named `UserDefaults` suite for UI-only state (the selected Settings tab).
    /// It also held the settings before settings.json; `openComposer` migrates them
    /// once.
    static let suiteName = "dev.nuhu.labs.Byakaron.shared"

    static let defaults = UserDefaults(suiteName: suiteName) ?? .standard

    /// `~/Library/Application Support/Byakaron`. The keyboard and the default app
    /// build run unsandboxed, so this is the user's real Application Support folder.
    static var dataDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Byakaron", isDirectory: true)
    }

    /// Open a composer on `dataDirectory`, after the one-time migrations from the
    /// pre-composer builds. `spellDB` (the bundled Byakaron.db) enables spelling
    /// corrections; `onUpdate(userdata)` is then called on a worker thread when
    /// they arrive.
    static func openComposer(
        spellDB: String? = nil,
        onUpdate: ByakaronUpdateFn? = nil,
        userdata: UnsafeMutableRawPointer? = nil
    ) -> OpaquePointer? {
        let dir = dataDirectory
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Learned choices used to be ac-selections.json.
        let oldSelections = dir.appendingPathComponent("ac-selections.json")
        let selections = dir.appendingPathComponent("selections.json")
        if fm.fileExists(atPath: oldSelections.path), !fm.fileExists(atPath: selections.path) {
            try? fm.moveItem(at: oldSelections, to: selections)
        }

        let needsMigration = !fm.fileExists(atPath: dir.appendingPathComponent("settings.json").path)
        guard let composer = byakaron_composer_create(dir.path, spellDB, onUpdate, userdata) else {
            NSLog("Byakaron: failed to open the composer on %@", dir.path)
            return nil
        }
        if needsMigration { migrateLegacySettings(composer) }
        return composer
    }

    // MARK: - Shared settings

    /// The settings every Byakaron keyboard shares (JSON field names from
    /// src/Composer/Settings.zig).
    struct Values: Codable, Equatable {
        var suggestions = true
        var spellingCorrections = true
        var learnChoices = true
        var banglaDigits = true
        var newlineOnEnter = false
        var candidateOrientation = Orientation.horizontal
        var candidatesPerPage = 9

        enum CodingKeys: String, CodingKey {
            case suggestions
            case spellingCorrections = "spelling_corrections"
            case learnChoices = "learn_choices"
            case banglaDigits = "bangla_digits"
            case newlineOnEnter = "newline_on_enter"
            case candidateOrientation = "candidate_orientation"
            case candidatesPerPage = "candidates_per_page"
        }
    }

    enum Orientation: String, Codable, CaseIterable, Identifiable {
        case horizontal
        case vertical
        var id: String { rawValue }
        var label: String {
            switch self {
            case .horizontal: return "Horizontal"
            case .vertical: return "Vertical"
            }
        }
    }

    static let candidatesPerPageRange = 3...9

    static func get(_ composer: OpaquePointer) -> Values {
        guard let cstr = byakaron_settings_get(composer) else { return Values() }
        defer { byakaron_string_free(cstr) }
        return (try? JSONDecoder().decode(Values.self, from: Data(String(cString: cstr).utf8))) ?? Values()
    }

    static func set(_ values: Values, _ composer: OpaquePointer) {
        guard let data = try? JSONEncoder().encode(values),
            let json = String(data: data, encoding: .utf8)
        else { return }
        if byakaron_settings_set(composer, json) != 0 {
            NSLog("Byakaron: failed to save settings")
        }
    }

    // MARK: - Personal dictionary

    static func userWords(_ composer: OpaquePointer) -> [String] {
        guard let cstr = byakaron_userdict_get(composer) else { return [] }
        defer { byakaron_string_free(cstr) }
        return (try? JSONDecoder().decode([String].self, from: Data(String(cString: cstr).utf8))) ?? []
    }

    // MARK: - Migration

    /// Carry the settings the old builds kept in the shared suite over to
    /// settings.json, then drop every key those builds wrote (most were never read).
    private static func migrateLegacySettings(_ composer: OpaquePointer) {
        let d = defaults
        var v = Values()
        if d.object(forKey: "ByakaronPhoneticOnlyMode") != nil {
            v.suggestions = !d.bool(forKey: "ByakaronPhoneticOnlyMode")
        }
        if let raw = d.string(forKey: "ByakaronCandidateOrientation"), let o = Orientation(rawValue: raw) {
            v.candidateOrientation = o
        }
        if d.object(forKey: "ByakaronCandidatesPerPage") != nil {
            v.candidatesPerPage = d.integer(forKey: "ByakaronCandidatesPerPage")
        }
        if d.object(forKey: "ByakaronSmartDigits") != nil {
            v.banglaDigits = d.bool(forKey: "ByakaronSmartDigits")
        }
        set(v, composer)

        for key in [
            "ByakaronPhoneticOnlyMode", "ByakaronCandidateOrientation", "ByakaronCandidatesPerPage",
            "ByakaronSmartDigits", "ByakaronCandidateFontSize", "ByakaronUseZigTransliteration",
            "ByakaronStartAtLogin", "ByakaronShowInMenuBar", "ByakaronUpdateChannel", "ByakaronAutoUpdate",
            "ByakaronAutoCorrect", "ByakaronAutoVowel", "ByakaronLearnWords", "ByakaronKeyboardLayout",
            "ByakaronShowEnglish", "ByakaronShowEmoji",
        ] {
            d.removeObject(forKey: key)
        }
    }
}
