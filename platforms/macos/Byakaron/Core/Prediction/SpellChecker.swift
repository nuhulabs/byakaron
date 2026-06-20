import Foundation
import SwiftUI
import Combine

/// A misspelled span found in the text: the word and its character range.
struct Misspelling: Identifiable, Hashable {
    let id = UUID()
    let word: String
    let range: Range<String.Index>
}

/// Observable model driving the editor: holds the text, the loaded engine, and
/// the current list of misspellings. Re-checks (debounced) whenever text changes.
@MainActor
final class SpellChecker: ObservableObject {

    @Published var text: String = "" {
        didSet { scheduleCheck() }
    }

    /// Misspelled spans in `text`, recomputed after edits settle.
    @Published private(set) var misspellings: [Misspelling] = []

    /// nil while the dictionary index is still loading.
    @Published private(set) var engine: SpellEngine?

    private var checkTask: Task<Void, Never>?

    init() {
        loadEngine()
    }

    #if DEBUG
    /// Preview/test seam: build a checker with canned state and no engine load,
    /// so SwiftUI previews render instantly without the bundled dictionary.
    static func preview(text: String = "", misspellings: [Misspelling] = []) -> SpellChecker {
        let checker = SpellChecker(skipLoad: ())
        checker.text = text
        checker.misspellings = misspellings
        return checker
    }

    private init(skipLoad: Void) {}
    #endif

    /// Build the engine off the main actor so the UI can show a loading state
    /// instead of freezing for the ~1.7 s index build.
    private func loadEngine() {
        Task.detached(priority: .userInitiated) {
            let engine = SpellEngine.loadFromBundle()
            await MainActor.run {
                self.engine = engine
                self.runCheck()
            }
        }
    }

    /// Debounce: coalesce rapid keystrokes into one check.
    private func scheduleCheck() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.runCheck()
        }
    }

    /// Recompute misspellings for the current text. Cheap (Set lookups), but we
    /// still hop the tokenization off-actor for very large pastes.
    func runCheck() {
        guard let engine else { return }
        let snapshot = text
        Task.detached(priority: .utility) {
            let found = Self.findMisspellings(in: snapshot, using: engine)
            await MainActor.run {
                // Ignore stale results if the text moved on.
                guard self.text == snapshot else { return }
                self.misspellings = found
            }
        }
    }

    /// Walk word boundaries, collecting tokens the engine rejects.
    nonisolated private static func findMisspellings(in text: String, using engine: SpellEngine) -> [Misspelling] {
        var result: [Misspelling] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { sub, range, _, _ in
            guard let sub else { return }
            if !engine.isCorrect(sub) {
                result.append(Misspelling(word: sub, range: range))
            }
        }
        return result
    }

    /// Correction candidates for a word.
    func suggestions(for word: String) -> [String] {
        engine?.suggestions(for: word) ?? []
    }

    /// Whether a token is spelled correctly. Used by the native editor to drive
    /// spelling underlines. Unknown engine (still loading) → treat as correct so
    /// nothing is flagged prematurely.
    func isCorrect(_ word: String) -> Bool {
        engine?.isCorrect(word) ?? true
    }

    /// Accept a word for the rest of the session (from the editor's context menu),
    /// then refresh the issue list.
    func learn(_ word: String) {
        engine?.learn(word)
        runCheck()
    }

    /// Replace a misspelled span with a chosen correction.
    func apply(_ correction: String, to misspelling: Misspelling) {
        guard text.indices.contains(misspelling.range.lowerBound) else { return }
        text.replaceSubrange(misspelling.range, with: correction)
    }

    /// Accept a word for the rest of the session and drop it from the list.
    func ignore(_ misspelling: Misspelling) {
        engine?.learn(misspelling.word)
        runCheck()
    }

    /// Replace every current misspelling that has at least one suggestion with
    /// its top-ranked correction, in one pass. Walks from the end of the text so
    /// earlier ranges stay valid as we splice in replacements of differing length.
    /// Returns how many words were corrected.
    @discardableResult
    func fixAll() -> Int {
        let fixes = misspellings
            .compactMap { miss -> (Range<String.Index>, String)? in
                guard let top = suggestions(for: miss.word).first else { return nil }
                return (miss.range, top)
            }
            .sorted { $0.0.lowerBound > $1.0.lowerBound }

        var corrected = 0
        for (range, replacement) in fixes {
            guard text.indices.contains(range.lowerBound) else { continue }
            text.replaceSubrange(range, with: replacement)
            corrected += 1
        }
        return corrected
    }
}
