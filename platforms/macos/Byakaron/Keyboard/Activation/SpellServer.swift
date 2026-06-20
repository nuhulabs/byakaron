import Cocoa

/// NSSpellServer delegate providing Bangla spell checking.
///
/// macOS may no longer honor third-party NSSpellServer language vendors on
/// recent releases (the route is largely inert), but we register it anyway per
/// product decision. It loads the SAME `data/dictionary.json` the IME bundles
/// (format: `[String: [String]]`) into a `Set<String>` for O(1) membership, and
/// uses a deletion-index for fast edit-distance suggestions — mirroring the
/// SwiftUI app's SpellEngine.
final class ByakaronSpellServerDelegate: NSObject, NSSpellServerDelegate {

    private let words: Set<String>
    private let deletionIndex: [String: [String]]

    override init() {
        var loaded = Set<String>()
        if let dir = Bundle.main.resourcePath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/data/dictionary.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            for (_, list) in object { loaded.formUnion(list) }
        } else {
            NSLog("Byakaron SpellServer: failed to load data/dictionary.json")
        }
        self.words = loaded

        var index: [String: [String]] = [:]
        index.reserveCapacity(loaded.count * 4)
        for word in loaded {
            for variant in Self.deletes1(Array(word)) {
                index[variant, default: []].append(word)
            }
        }
        self.deletionIndex = index
        NSLog("Byakaron SpellServer: loaded %d words", loaded.count)
        super.init()
    }

    // MARK: - NSSpellServerDelegate

    func spellServer(_ sender: NSSpellServer,
                     findMisspelledWordIn stringToCheck: String,
                     language: String,
                     wordCount: UnsafeMutablePointer<Int>,
                     countOnly: Bool) -> NSRange {
        let ns = stringToCheck as NSString
        var count = 0
        var firstMisspelled = NSRange(location: NSNotFound, length: 0)

        let opts: NSString.EnumerationOptions = [.byWords, .localized]
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: opts) { word, range, _, stop in
            guard let word = word else { return }
            count += 1
            if !countOnly, !self.isCorrect(word) {
                firstMisspelled = range
                stop.pointee = true
            }
        }

        wordCount.pointee = count
        return countOnly ? NSRange(location: NSNotFound, length: 0) : firstMisspelled
    }

    func spellServer(_ sender: NSSpellServer,
                     suggestGuessesForWord word: String,
                     inLanguage language: String) -> [String]? {
        suggestions(for: word)
    }

    // MARK: - Checking

    private func isCorrect(_ word: String) -> Bool {
        if word.isEmpty { return true }
        if !word.unicodeScalars.contains(where: Self.isBengaliLetter) { return true }
        return words.contains(word)
    }

    private func suggestions(for word: String, limit: Int = 8) -> [String] {
        let wordChars = Array(word)
        var candidates = Set<String>()
        for variant in Self.deletes1(wordChars) {
            if let hits = deletionIndex[variant] { candidates.formUnion(hits) }
        }
        candidates.remove(word)

        return candidates
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

    private static func boundedEditDistance(_ a: [Character], _ b: [Character], max: Int) -> Int {
        let la = a.count, lb = b.count
        if abs(la - lb) > max { return max + 1 }
        if lb == 0 { return la }

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

    private static func isBengaliLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0980...0x09FF).contains(Int(scalar.value))
    }
}
