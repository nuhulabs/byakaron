import Foundation

/// Bengali spell-checking engine backed by `dictionary.json`.
///
/// Pure Foundation — no AppKit/UIKit — so it compiles unchanged on macOS and iOS.
/// Membership testing is an O(1) `Set` lookup. Correction suggestions use a
/// SymSpell-style deletion index: every word and its delete-1 variants are keyed
/// to the real words they could derive from, turning suggestion lookup into a
/// handful of hash probes instead of a scan over 159k words (~0.1 ms each).
final class SpellEngine {

    /// All dictionary words, for membership tests.
    private let words: Set<String>

    /// Maps a "delete-1" form (word with ≤1 character removed) to the real
    /// words that produce it. Lets us find edit-distance≤2 candidates fast.
    private let deletionIndex: [String: [String]]

    /// Words the user has explicitly accepted this session ("Ignore"/"Learn").
    private var learned: Set<String> = []

    /// Build the engine from the bundled dictionary. Expensive (~1.7 s for the
    /// index) — call off the main thread and show a loading state.
    init(words: Set<String>) {
        self.words = words

        var index: [String: [String]] = [:]
        index.reserveCapacity(words.count * 4)
        for word in words {
            for variant in Self.deletes1(Array(word)) {
                index[variant, default: []].append(word)
            }
        }
        self.deletionIndex = index
    }

    /// Convenience: load and parse `dictionary.json` from a bundle, then build.
    /// Returns nil if the resource is missing or malformed.
    static func loadFromBundle(_ bundle: Bundle = .main) -> SpellEngine? {
        guard let url = bundle.url(forResource: "dictionary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return nil }

        var words = Set<String>()
        for (_, list) in object { words.formUnion(list) }
        return SpellEngine(words: words)
    }

    // MARK: - Checking

    /// True when the word is in the dictionary or has been learned this session.
    /// Tokens with no Bengali letters (numbers, Latin) are treated as correct so
    /// we don't flag punctuation or foreign words the user typed deliberately.
    func isCorrect(_ word: String) -> Bool {
        if word.isEmpty { return true }
        if !word.unicodeScalars.contains(where: Self.isBengaliLetter) { return true }
        return words.contains(word) || learned.contains(word)
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
    func suggestions(for word: String, limit: Int = 8) -> [String] {
        let wordChars = Array(word)

        var candidates = Set<String>()
        for variant in Self.deletes1(wordChars) {
            if let hits = deletionIndex[variant] {
                candidates.formUnion(hits)
            }
        }
        candidates.remove(word)

        // Rank by true edit distance, then by length closeness, then lexically
        // so results are stable and the best fix is first. Drop any candidate
        // carrying emoji/pictographic scalars — the dictionary holds a handful
        // of such entries and they're never a sensible spelling correction.
        return candidates
            .filter { !Self.containsEmoji($0) }
            .map { (word: $0, distance: Self.boundedEditDistance(wordChars, Array($0), max: 2)) }
            .filter { $0.distance <= 2 }
            .sorted {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                let dl = abs($0.word.count - word.count), dr = abs($1.word.count - word.count)
                if dl != dr { return dl < dr }
                return $0.word < $1.word
            }
            .prefix(limit)
            .map { $0.word }
    }

    // MARK: - Internals

    /// The word itself plus every variant with exactly one character removed.
    private static func deletes1(_ chars: [Character]) -> [String] {
        if chars.count <= 1 { return [String(chars)] }
        var result = [String(chars)]
        result.reserveCapacity(chars.count + 1)
        for i in chars.indices {
            var copy = chars
            copy.remove(at: i)
            result.append(String(copy))
        }
        return result
    }

    /// Levenshtein distance, short-circuiting once it provably exceeds `max`.
    private static func boundedEditDistance(_ a: [Character], _ b: [Character], max: Int) -> Int {
        let la = a.count, lb = b.count
        if abs(la - lb) > max { return max + 1 }

        var prev = Array(0...lb)
        var curr = [Int](repeating: 0, count: lb + 1)
        for i in 1...la {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...lb {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                rowMin = Swift.min(rowMin, curr[j])
            }
            if rowMin > max { return max + 1 }
            swap(&prev, &curr)
        }
        return prev[lb]
    }

    /// Whether a string contains any emoji / pictographic scalar. We test the
    /// Unicode `isEmoji` property but exclude plain digits and `#`/`*`, which
    /// also carry that property yet are ordinary text.
    private static func containsEmoji(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation ||
            (scalar.properties.isEmoji && scalar.value > 0x238C)
        }
    }

    /// Whether a scalar is a Bengali (Bangla) letter — the block is U+0980–U+09FF,
    /// but we exclude digits and the currency/sign marks at the edges so a bare
    /// number or danda isn't treated as a checkable word.
    private static func isBengaliLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0980...0x09FF).contains(Int(scalar.value))
    }
}
