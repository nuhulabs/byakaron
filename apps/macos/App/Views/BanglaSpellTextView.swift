import SwiftUI
import AppKit

/// A native `NSTextView` editor that renders the system's spell-checking UX —
/// red squiggly underlines and a right-click corrections menu — for Bangla.
///
/// We can't use `NSSpellChecker`'s built-in language engine: macOS has no `bn`
/// checker (verified — `availableLanguages` excludes it and no third-party
/// vendor or Hunspell drop-in activates it on macOS 27). So we keep the native
/// `NSSpellChecker` *presentation* — `NSAttributedString.Key.spellingState`
/// temporary attributes for the underlines, and an `NSMenu` of guesses for the
/// context menu — but source every correctness decision and suggestion from our
/// own `SpellEngine`.
struct BanglaSpellTextView: NSViewRepresentable {
    @Binding var text: String

    /// When set, scroll/reveal this misspelled span in the editor.
    var selectedRange: Range<String.Index>?

    /// Returns whether a token is spelled correctly.
    let isCorrect: (String) -> Bool
    /// Ranked corrections for a misspelled token at a known range (for context).
    let suggestions: (String, Range<String.Index>) -> [String]
    /// Called when the user accepts a word ("Learn"/"Ignore") from the menu.
    let onLearn: (String) -> Void
    /// Called just before a context-menu correction is committed, with the
    /// UTF-16 range being replaced and the replacement's UTF-16 length — so the
    /// parent can jump the issue list to the next misspelling.
    var onApplied: ((NSRange, Int) -> Void)? = nil
    /// Type through the Byakaron keyboard's composer here ("Avro typing"), to
    /// try the keyboard without installing it. See `ComposingTextView`.
    var avroTyping = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // `NSTextView.scrollableTextView()`, but with our composing subclass.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = ComposingTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        textView.avroTyping = avroTyping

        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 18)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.drawsBackground = false

        // We drive spell underlines ourselves, so turn off the system's own
        // continuous checking (it would only check English anyway).
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false

        scroll.drawsBackground = false
        context.coordinator.textView = textView
        context.coordinator.recheck()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ComposingTextView else { return }
        context.coordinator.parent = self
        textView.avroTyping = avroTyping
        // Sync text in when it changed from outside (e.g. a correction applied
        // from the sidebar), then always re-underline: a SwiftUI update can also
        // reach us with the *same* text but changed correctness — e.g. "Ignore"
        // in the sidebar — and the ignored word must stop squiggling.
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        context.coordinator.recheck()
        context.coordinator.revealSelectionIfNeeded()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BanglaSpellTextView
        weak var textView: NSTextView?

        /// Debounce token so rapid typing coalesces into one recheck.
        private var pendingRecheck: DispatchWorkItem?

        /// Last range we scrolled to, so we don't fight the user while they type.
        private var lastRevealed: Range<String.Index>?

        init(_ parent: BanglaSpellTextView) {
            self.parent = parent
        }

        // MARK: Editing

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            scheduleRecheck()
        }

        private func scheduleRecheck() {
            pendingRecheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.recheck() }
            pendingRecheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        /// Recompute misspelled ranges and apply native spelling underlines.
        func recheck() {
            guard let textView, let storage = textView.textStorage else { return }
            let ns = textView.string as NSString
            let full = NSRange(location: 0, length: ns.length)

            // Clear existing spelling marks, then re-mark current misspellings.
            textView.layoutManager?.removeTemporaryAttribute(.spellingState, forCharacterRange: full)

            ns.enumerateSubstrings(in: full, options: [.byWords]) { word, range, _, _ in
                guard let word, !self.parent.isCorrect(word) else { return }
                textView.layoutManager?.addTemporaryAttribute(
                    .spellingState,
                    value: NSAttributedString.SpellingState.spelling.rawValue,
                    forCharacterRange: range
                )
            }
            _ = storage // silence unused in case layoutManager is nil
        }

        /// Scroll the selected misspelling into view when the sidebar selection moves.
        func revealSelectionIfNeeded() {
            guard let textView, let selected = parent.selectedRange else { return }
            guard selected != lastRevealed else { return }
            lastRevealed = selected
            let nsRange = NSRange(selected, in: parent.text)
            guard nsRange.location != NSNotFound else { return }
            textView.scrollRangeToVisible(nsRange)
            textView.setSelectedRange(nsRange)
        }

        // MARK: Context menu

        /// Inject our Bangla corrections at the top of the right-click menu when
        /// the click lands on a misspelled word.
        func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let ns = textView.string as NSString
            guard charIndex < ns.length else { return menu }

            let wordRange = ns.rangeOfWord(at: charIndex)
            guard wordRange.location != NSNotFound, wordRange.length > 0 else { return menu }
            let word = ns.substring(with: wordRange)
            guard !parent.isCorrect(word) else { return menu }

            let swiftRange = Range(wordRange, in: parent.text) ?? parent.text.startIndex..<parent.text.startIndex

            var insertAt = 0
            let guesses = parent.suggestions(word, swiftRange)
            if guesses.isEmpty {
                let none = NSMenuItem(title: "No suggestions", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.insertItem(none, at: insertAt); insertAt += 1
            } else {
                for guess in guesses {
                    let item = NSMenuItem(title: guess, action: #selector(applyCorrection(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = Correction(range: wordRange, replacement: guess)
                    menu.insertItem(item, at: insertAt); insertAt += 1
                }
            }

            let learn = NSMenuItem(title: "Ignore Spelling", action: #selector(learnWord(_:)), keyEquivalent: "")
            learn.target = self
            learn.representedObject = word
            menu.insertItem(learn, at: insertAt); insertAt += 1
            menu.insertItem(.separator(), at: insertAt)
            return menu
        }

        private struct Correction { let range: NSRange; let replacement: String }

        @objc private func applyCorrection(_ sender: NSMenuItem) {
            guard let textView, let c = sender.representedObject as? Correction else { return }
            let replacementUTF16 = (c.replacement as NSString).length
            parent.onApplied?(c.range, replacementUTF16)
            if textView.shouldChangeText(in: c.range, replacementString: c.replacement) {
                textView.replaceCharacters(in: c.range, with: c.replacement)
                textView.didChangeText()
            }
            parent.text = textView.string
            recheck()
        }

        @objc private func learnWord(_ sender: NSMenuItem) {
            guard let word = sender.representedObject as? String else { return }
            parent.onLearn(word)
            recheck()
        }
    }
}

private extension NSString {
    /// The range of the whole word containing `index`, using word-boundary
    /// enumeration so it matches how we tokenize for checking.
    func rangeOfWord(at index: Int) -> NSRange {
        var found = NSRange(location: NSNotFound, length: 0)
        enumerateSubstrings(in: NSRange(location: 0, length: length), options: [.byWords]) { _, range, _, stop in
            if NSLocationInRange(index, range) || range.location == index {
                found = range
                stop.pointee = true
            }
        }
        return found
    }
}
