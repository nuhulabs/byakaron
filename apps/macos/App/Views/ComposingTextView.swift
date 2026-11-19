import AppKit

/// The app's composer for "Avro typing": the same engine, settings, learned
/// choices and personal dictionary as the installed keyboard (they share
/// `ByakaronSettings.dataDirectory`), so the keyboard's typing and suggestions
/// can be tried here without installing it and logging out. Main thread only.
enum AppComposer {
    static let handle: OpaquePointer? = ByakaronSettings.openComposer(
        spellDB: Bundle.main.url(forResource: "Byakaron", withExtension: "db")?.path,
        onUpdate: { _ in
            // Spelling corrections arrived on the composer's worker thread.
            DispatchQueue.main.async {
                guard let handle = AppComposer.handle else { return }
                byakaron_composer_refresh(handle)
                ComposingTextView.active?.redraw()
            }
        }
    )
}

/// An `NSTextView` that, while `avroTyping` is on, sends key events to the
/// composer the way the keyboard (`ByakaronInputController`) does: the
/// highlighted candidate is the marked text, commits are inserted, keys the
/// composer does not consume reach the text view as usual, and the candidates
/// show in `CandidatePanel`, the keyboard's own panel.
final class ComposingTextView: NSTextView {
    /// The view whose composer state is on screen, redrawn when corrections arrive.
    fileprivate static weak var active: ComposingTextView?

    var avroTyping = false {
        didSet {
            guard avroTyping != oldValue else { return }
            if !avroTyping { flush() }
        }
    }

    private lazy var candidatePanel = CandidatePanel(
        onPick: { [weak self] index in
            guard let self, let composer = AppComposer.handle else { return }
            self.apply(byakaron_composer_pick(composer, index))
        },
        onPage: { [weak self] next in
            guard let self, let composer = AppComposer.handle else { return }
            let key = next ? BYAKARON_KEY_PAGE_DOWN : BYAKARON_KEY_PAGE_UP
            self.apply(byakaron_composer_key(composer, Int32(key), 0, 0))
        }
    )

    override func keyDown(with event: NSEvent) {
        guard avroTyping, let composer = AppComposer.handle else {
            super.keyDown(with: event)
            return
        }
        Self.active = self
        if !apply(ComposerKeys.send(event, to: composer)) {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        flush()  // the caret is about to leave the word
        super.mouseDown(with: event)
    }

    /// ⌘A comes through the menu, not `keyDown`, so the word would stay marked
    /// and composing under the new selection: Backspace then deleted the rest
    /// and the composer redrew the word. Commit it first, so what is selected
    /// is all plain text and the next key acts on it.
    override func selectAll(_ sender: Any?) {
        flush()
        super.selectAll(sender)
    }

    override func resignFirstResponder() -> Bool {
        flush()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { flush() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Insert the result's commit, redraw, and report whether the key was consumed.
    @discardableResult
    private func apply(_ result: ByakaronKeyResult) -> Bool {
        if let commit = result.commitText { commitText(commit) }
        redraw()
        return result.handled != 0
    }

    /// Commit the word being typed where it stands.
    func flush() {
        guard let composer = AppComposer.handle, hasMarkedText() else {
            candidatePanel.orderOut(nil)
            return
        }
        if let text = byakaron_composer_flush(composer), text.pointee != 0 {
            commitText(String(cString: text))
        }
        redraw()
    }

    /// Replace the marked text (the word being composed) with `text`.
    private func commitText(_ text: String) {
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Draw the composer's state: the highlighted candidate as marked text and
    /// the current page in the candidate panel.
    fileprivate func redraw() {
        guard let composer = AppComposer.handle else { return }
        let state = ComposerSnapshot(composer)
        if state.composing {
            setMarkedText(
                state.preedit,
                selectedRange: NSRange(location: (state.preedit as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        } else if hasMarkedText() {
            // The word was dropped (Esc, or Backspace to empty): commits arrive
            // through `commitText`, so whatever is still marked goes.
            insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        guard state.panelVisible, !state.candidates.isEmpty, let window else {
            candidatePanel.orderOut(nil)
            return
        }
        // Below the marked text, like the keyboard's panel.
        var actual = NSRange()
        let caret = firstRect(forCharacterRange: markedRange(), actualRange: &actual)
        candidatePanel.show(state, below: caret, parent: window)
    }
}
