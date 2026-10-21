import Foundation

/// Dictionary-backed suggestion source for the Zig (inline phonetic) input mode.
///
/// Uses the Zig `AutoComplete/Mem` lexicon (Avro dictionary, embedded at
/// compile time) for Bangla prefix completions, plus bundled `Suffix.json` for
/// suffix-derived candidates. Latin → Bangla still goes through the Zig
/// transliterator.
///
/// Loading opens the Mem engine once on a background queue. Until the shared
/// instance is ready, the Zig mode shows the live transliteration with no
/// candidate window.
final class PhoneticDictionary {

    /// Process-wide instance, populated by `preload()`. Read on the main thread.
    private(set) static var shared: PhoneticDictionary?
    private static var loading = false

    private var handle: OpaquePointer?
    /// Latin suffix → Bangla suffix (suffix.json).
    private let suffixes: [String: String]

    private init(handle: OpaquePointer, suffixes: [String: String]) {
        self.handle = handle
        self.suffixes = suffixes
    }

    deinit {
        if let handle {
            byakaron_ac_destroy(handle)
        }
    }

    /// Kick off a one-time background load of the shared dictionary. Safe to call
    /// repeatedly; only the first call does work.
    static func preload(_ bundle: Bundle = .main) {
        guard shared == nil, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let dict = PhoneticDictionary.loadFromBundle(bundle)
            DispatchQueue.main.async {
                shared = dict
                loading = false
                NSLog("Byakaron: PhoneticDictionary loaded (Zig Mem autocomplete)")
            }
        }
    }

    /// Open the Zig Mem autocomplete engine and optional `Suffix.json`.
    static func loadFromBundle(_ bundle: Bundle = .main) -> PhoneticDictionary? {
        guard let handle = byakaron_ac_create() else { return nil }

        var suffixObj: [String: String] = [:]
        if let dir = bundle.resourcePath,
            let suffixData = try? Data(contentsOf: URL(fileURLWithPath: dir + "/Suffix.json")),
            let parsed = try? JSONSerialization.jsonObject(with: suffixData) as? [String: String]
        {
            suffixObj = parsed
        }

        return PhoneticDictionary(handle: handle, suffixes: suffixObj)
    }

    // MARK: - Suggestions

    /// Ordered, de-duplicated Bangla candidates for the Latin `input`.
    ///
    /// The live phonetic transliteration is always the first candidate so the
    /// default commit matches the marked (underlined) text the user sees.
    func suggestions(forLatin input: String, limit: Int = 24) -> [String] {
        let phonetic = Transliterator.toBangla(input)
        guard !phonetic.isEmpty else { return [] }

        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            guard !s.isEmpty, seen.insert(s).inserted else { return }
            ordered.append(s)
        }

        // 1. Phonetic transliteration (default selection).
        add(phonetic)
        // 2. Dictionary completions for the phonetic form (exact + longer words).
        for w in prefixMatches(phonetic, limit: limit) { add(w) }
        // 3. Suffix-derived candidates (e.g. computer + gulo → কম্পিউটারগুলো).
        for w in suffixMatches(forLatin: input, limit: limit) { add(w) }

        return Array(ordered.prefix(limit))
    }

    // MARK: - Internals

    /// Dictionary words having `prefix`, ordered by the Zig AutoComplete ranker
    /// (shortest-first).
    private func prefixMatches(_ prefix: String, limit: Int) -> [String] {
        guard let handle, !prefix.isEmpty else { return [] }
        guard let cstr = byakaron_ac_prefix(handle, prefix, Int32(limit)) else { return [] }
        defer { byakaron_string_free(cstr) }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }

    private func containsWord(_ word: String) -> Bool {
        guard let handle else { return false }
        return byakaron_ac_contains(handle, word) == 1
    }

    /// Split the Latin input at each position; if the tail is a known suffix,
    /// transliterate the head and append the suffix to the head's dictionary
    /// matches. Longer stems (shorter suffixes) are preferred.
    private func suffixMatches(forLatin input: String, limit: Int) -> [String] {
        let chars = Array(input)
        guard chars.count > 2 else { return [] }

        var results: [String] = []
        for i in stride(from: chars.count - 1, through: 1, by: -1) {
            let suffixKey = String(chars[i...])
            guard let suffixBangla = suffixes[suffixKey] else { continue }
            let stemBangla = Transliterator.toBangla(String(chars[0..<i]))
            guard !stemBangla.isEmpty else { continue }

            var bases: [String] = []
            if containsWord(stemBangla) { bases.append(stemBangla) }
            for w in prefixMatches(stemBangla, limit: 4) where !bases.contains(w) {
                bases.append(w)
            }
            if bases.isEmpty { bases.append(stemBangla) }

            for base in bases {
                results.append(Self.join(base: base, suffix: suffixBangla))
                if results.count >= limit { return results }
            }
        }
        return results
    }

    /// Join a base word with a suffix, applying riti's boundary fix-ups.
    private static func join(base: String, suffix: String) -> String {
        guard let last = base.last, let suffixFirst = suffix.first else {
            return base + suffix
        }
        var word = base
        if isVowel(last) && isKar(suffixFirst) {
            word.append("\u{09DF}")  // insert য় between a trailing vowel and a kar
        } else if last == "\u{09CE}" {
            word.removeLast()
            word.append("\u{09A4}")  // ৎ → ত
        } else if last == "\u{0982}" {
            word.removeLast()
            word.append("\u{0999}")  // ং → ঙ
        }
        return word + suffix
    }

    /// Bengali independent vowels (অ … ঔ).
    private static func isVowel(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return (0x0985...0x0994).contains(s.value)
    }

    /// Bengali dependent vowel signs / kars (া … ৌ, ৗ).
    private static func isKar(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return (0x09BE...0x09CC).contains(s.value) || s.value == 0x09D7
    }
}
