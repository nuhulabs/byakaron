import Foundation

/// Dictionary-backed suggestion source for the Zig (inline phonetic) input mode.
///
/// Fully self-contained: it uses the bundled `dictionary.json` (the Avro word
/// list, keyed by first-letter group) and `suffix.json`, combined with the Zig
/// transliterator, to produce Bangla candidates for a run of Latin keystrokes.
///
/// Matching strategy: the Zig engine already renders Latin → Bangla with correct
/// inherent vowels, so we transliterate the typed text and look the result up as
/// a *prefix* in the sorted word list. That yields the exact word plus longer
/// completions. Suffix support splits the Latin input, transliterates the stem,
/// and appends a known suffix (suffix.json) using the same joining rules riti
/// applies (vowel + kar → য়, ৎ → ত, ং → ঙ).
///
/// Loading sorts ~160k words, so it is done once on a background queue. Until the
/// shared instance is ready, the Zig mode simply shows the live transliteration
/// with no candidate window.
final class PhoneticDictionary {

    /// Process-wide instance, populated by `preload()`. Read on the main thread.
    private(set) static var shared: PhoneticDictionary?
    private static var loading = false

    /// All dictionary words, sorted (by Unicode scalars) for binary-search prefix
    /// lookup.
    private let sortedWords: [String]
    /// Membership set for O(1) exact lookups.
    private let wordSet: Set<String>
    /// Latin suffix → Bangla suffix (suffix.json).
    private let suffixes: [String: String]

    private init(sortedWords: [String], wordSet: Set<String>, suffixes: [String: String]) {
        self.sortedWords = sortedWords
        self.wordSet = wordSet
        self.suffixes = suffixes
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
                NSLog("Byakaron: PhoneticDictionary loaded (%d words)", dict?.sortedWords.count ?? 0)
            }
        }
    }

    /// Load `dictionary.json` and `suffix.json` from the bundle's `Resources/data`
    /// directory. Returns nil if the dictionary is missing/malformed.
    static func loadFromBundle(_ bundle: Bundle = .main) -> PhoneticDictionary? {
        guard let dir = bundle.resourcePath else { return nil }
        let dataDir = dir + "/data"

        guard let dictData = try? Data(contentsOf: URL(fileURLWithPath: dataDir + "/dictionary.json")),
              let dictObj = try? JSONSerialization.jsonObject(with: dictData) as? [String: [String]]
        else { return nil }

        var set = Set<String>()
        for (_, list) in dictObj { set.formUnion(list) }

        // suffix.json is optional — suffix completions just won't appear without it.
        var suffixObj: [String: String] = [:]
        if let suffixData = try? Data(contentsOf: URL(fileURLWithPath: dataDir + "/suffix.json")),
           let parsed = try? JSONSerialization.jsonObject(with: suffixData) as? [String: String] {
            suffixObj = parsed
        }

        let sorted = set.sorted { Self.scalarLess($0, $1) }
        return PhoneticDictionary(sortedWords: sorted, wordSet: set, suffixes: suffixObj)
    }

    // MARK: - Suggestions

    /// Ordered, de-duplicated Bangla candidates for the Latin `input`.
    ///
    /// The live phonetic transliteration is always the first candidate so the
    /// default commit matches the marked (underlined) text the user sees.
    func suggestions(forLatin input: String, limit: Int = 24) -> [String] {
        let phonetic = ZigTransliterator.toBangla(input)
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

    /// Dictionary words having `prefix`, ordered shortest-first then by scalars so
    /// the exact match (when present) leads the completions.
    private func prefixMatches(_ prefix: String, limit: Int) -> [String] {
        guard !prefix.isEmpty else { return [] }
        var i = lowerBound(prefix)
        var hits: [String] = []
        let scanCap = limit * 6
        while i < sortedWords.count {
            let w = sortedWords[i]
            if !w.hasPrefix(prefix) { break }
            hits.append(w)
            i += 1
            if hits.count >= scanCap { break }
        }
        hits.sort {
            if $0.count != $1.count { return $0.count < $1.count }
            return Self.scalarLess($0, $1)
        }
        return Array(hits.prefix(limit))
    }

    /// First index in `sortedWords` whose element is >= `key` (scalar order).
    private func lowerBound(_ key: String) -> Int {
        var lo = 0, hi = sortedWords.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Self.scalarLess(sortedWords[mid], key) { lo = mid + 1 } else { hi = mid }
        }
        return lo
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
            let stemBangla = ZigTransliterator.toBangla(String(chars[0..<i]))
            guard !stemBangla.isEmpty else { continue }

            // Bases: the stem word itself plus a few dictionary completions.
            var bases: [String] = []
            if wordSet.contains(stemBangla) { bases.append(stemBangla) }
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
            word.append("\u{09DF}") // insert য় between a trailing vowel and a kar
        } else if last == "\u{09CE}" {
            word.removeLast()
            word.append("\u{09A4}") // ৎ → ত
        } else if last == "\u{0982}" {
            word.removeLast()
            word.append("\u{0999}") // ং → ঙ
        }
        return word + suffix
    }

    /// Lexicographic comparison by Unicode scalars — kept consistent between the
    /// sort, the binary search, and `hasPrefix` so prefixed words stay contiguous.
    private static func scalarLess(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
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
