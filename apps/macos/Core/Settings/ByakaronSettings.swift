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

    /// A setting by its manifest key: 0/1, an option's index or a number.
    static func value(_ key: String, _ composer: OpaquePointer) -> Int? {
        var v: Int32 = 0
        return byakaron_setting_get(composer, key, &v) == 0 ? Int(v) : nil
    }

    static func setValue(_ key: String, _ value: Int, _ composer: OpaquePointer) {
        if byakaron_setting_set(composer, key, Int32(value)) != 0 {
            NSLog("Byakaron: failed to save %@", key)
        }
    }

    // MARK: - Personal dictionary

    static func userWords(_ composer: OpaquePointer) -> [String] {
        (0..<byakaron_userdict_count(composer)).compactMap { i in
            byakaron_userdict_word(composer, i).map { String(cString: $0) }
        }
    }

    // MARK: - Migration

    /// Carry the settings the old builds kept in the shared suite over to
    /// settings.json, then drop every key those builds wrote (most were never read).
    private static func migrateLegacySettings(_ composer: OpaquePointer) {
        let d = defaults
        if d.object(forKey: "ByakaronPhoneticOnlyMode") != nil {
            setValue("suggestions", d.bool(forKey: "ByakaronPhoneticOnlyMode") ? 0 : 1, composer)
        }
        if let raw = d.string(forKey: "ByakaronCandidateOrientation") {
            setValue("candidate_orientation", raw == "vertical" ? 1 : 0, composer)
        }
        if d.object(forKey: "ByakaronCandidatesPerPage") != nil {
            setValue("candidates_per_page", d.integer(forKey: "ByakaronCandidatesPerPage"), composer)
        }
        if d.object(forKey: "ByakaronSmartDigits") != nil {
            setValue("bangla_digits", d.bool(forKey: "ByakaronSmartDigits") ? 1 : 0, composer)
        }

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

// MARK: - Manifest

/// What the settings screens show, from the shared manifest
/// (src/Composer/Settings.zig): sections and the fields macOS shows, in order,
/// with their text in the user's language.
enum SettingsManifest {
    struct Section: Identifiable {
        let id: Int
        let key: String
        let title: String
        let hint: String?
    }

    enum Control {
        case toggle
        case choice([String])
        case number(ClosedRange<Int>)
    }

    struct Field: Identifiable {
        var id: String { key }
        let key: String
        let section: Int
        let title: String
        let hint: String?
        let control: Control
    }

    private static let language = Locale.preferredLanguages.first ?? "en"

    static let sections: [Section] = (0..<byakaron_settings_section_count()).compactMap { i in
        var s = ByakaronSettingsSection()
        guard byakaron_settings_section_info(i, language, &s) == 0 else { return nil }
        return Section(
            id: i, key: String(cString: s.id), title: String(cString: s.title),
            hint: s.hint.map { String(cString: $0) })
    }

    static let fields: [Field] = (0..<byakaron_settings_field_count()).compactMap { i in
        var f = ByakaronSettingsField()
        guard byakaron_settings_field_info(i, language, &f) == 0,
            f.platforms & UInt32(BYAKARON_PLATFORM_MACOS) != 0
        else { return nil }
        let control: Control
        switch Int(f.control) {
        case Int(BYAKARON_CONTROL_TOGGLE):
            control = .toggle
        case Int(BYAKARON_CONTROL_CHOICE):
            control = .choice((0..<f.option_count).map { String(cString: f.option_labels[$0]!) })
        default:
            control = .number(Int(f.min)...Int(f.max))
        }
        return Field(
            key: String(cString: f.key), section: f.section, title: String(cString: f.title),
            hint: f.hint.map { String(cString: $0) }, control: control)
    }

    static func section(_ key: String) -> Section? { sections.first { $0.key == key } }

    static func fields(in section: Section) -> [Field] { fields.filter { $0.section == section.id } }
}

/// A settings label shared with every Byakaron app (src/locale/*.zon, generated
/// into byakaron_strings.h), in the user's first preferred language when there
/// is a locale for it, else English.
func tr(_ id: BykStr) -> String {
    String(cString: byk_str_in(byakaronLocale, id))
}

private let byakaronLocale = byk_locale_for(Locale.preferredLanguages.first ?? "en")
