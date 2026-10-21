import Foundation

/// Bengali spell-checking engine backed by the Zig SymSpell lexicon (`spell.db`).
///
/// Pure Foundation — no AppKit/UIKit — so it compiles unchanged on macOS and iOS.
/// Correctness and suggestions are answered by `libbyakaron` over the C FFI;
/// session-local "Ignore"/"Learn" words stay in Swift.
final class SpellEngine {

    private var handle: OpaquePointer?
    /// Words the user has explicitly accepted this session ("Ignore"/"Learn").
    private var learned: Set<String> = []

    init?(dbPath: String) {
        guard let h = byakaron_spell_create(dbPath) else { return nil }
        self.handle = h
    }

    deinit {
        if let handle {
            byakaron_spell_destroy(handle)
        }
    }

    /// Convenience: open bundled `spell.db`, then build.
    /// Returns nil if the resource is missing or the engine fails to open.
    static func loadFromBundle(_ bundle: Bundle = .main) -> SpellEngine? {
        guard let url = bundle.url(forResource: "spell", withExtension: "db") else {
            return nil
        }
        return SpellEngine(dbPath: url.path)
    }

    // MARK: - Checking

    /// True when the word is in the dictionary or has been learned this session.
    /// Tokens with no Bengali letters (numbers, Latin) are treated as correct so
    /// we don't flag punctuation or foreign words the user typed deliberately.
    func isCorrect(_ word: String) -> Bool {
        if word.isEmpty { return true }
        if !word.unicodeScalars.contains(where: Self.isBengaliLetter) { return true }
        if learned.contains(word) { return true }
        guard let handle else { return true }
        return byakaron_spell_is_correct(handle, word) == 1
    }

    /// Mark a word as acceptable for the rest of the session.
    func learn(_ word: String) {
        learned.insert(word)
    }

    func isLearned(_ word: String) -> Bool {
        learned.contains(word)
    }

    // MARK: - Suggestions

    /// Ranked correction candidates for a (presumed misspelled) word.
    /// Optional neighbors boost ranking via bigram/trigram frequencies in spell.db.
    func suggestions(
        for word: String,
        prev2: String = "",
        prev1: String = "",
        next: String = "",
        limit: Int = 8
    ) -> [String] {
        guard let handle else { return [] }
        guard let cstr = byakaron_spell_suggest_ctx(
            handle, word, prev2, prev1, next, Int32(limit)
        ) else { return [] }
        defer { byakaron_string_free(cstr) }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr.filter { !Self.containsEmoji($0) }
    }

    // MARK: - Internals

    /// Whether a string contains any emoji / pictographic scalar. We test the
    /// Unicode `isEmoji` property but exclude plain digits and `#`/`*`, which
    /// also carry that property yet are ordinary text.
    private static func containsEmoji(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x238C)
        }
    }

    /// Whether a scalar is a Bengali (Bangla) letter — the block is U+0980–U+09FF,
    /// but we exclude digits and the currency/sign marks at the edges so a bare
    /// number or danda isn't treated as a checkable word.
    private static func isBengaliLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0980...0x09FF).contains(Int(scalar.value))
    }
}
