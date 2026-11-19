import InputMethodKit
import os

/// `log stream --predicate 'subsystem == "dev.nuhu.labs.inputmethod.Byakaron"' --level info`
private let timing = Logger(subsystem: "dev.nuhu.labs.inputmethod.Byakaron", category: "timing")

/// The process's one composer (src/Composer.zig): it owns the word being typed,
/// the candidate list, the highlight, paging, learning and the personal
/// dictionary. IMK delivers every event on the main thread, so that is the
/// composer's thread.
private enum Composer {
    static let handle: OpaquePointer? = ByakaronSettings.openComposer(
        spellDB: Bundle.main.url(forResource: "Byakaron", withExtension: "db")?.path,
        onUpdate: { _ in
            // Spelling corrections arrived on the composer's worker thread.
            DispatchQueue.main.async {
                guard let handle = Composer.handle else { return }
                byakaron_composer_refresh(handle)
                ByakaronInputController.active?.redraw()
            }
        }
    )
}

@objc(ByakaronInputController)
class ByakaronInputController: IMKInputController {
    /// The controller of the focused client, redrawn when corrections arrive.
    fileprivate static weak var active: ByakaronInputController?

    /// The one candidate panel, kept for the process lifetime and shared by
    /// every client's controller: picks and page clicks go to the active one.
    /// We draw it (`CandidatePanel`) rather than use `IMKCandidates`, whose
    /// highlight would not follow the composer's in a horizontal panel.
    private static let candidatePanel = CandidatePanel(
        onPick: { index in
            guard let composer = Composer.handle, let controller = active else { return }
            controller.apply(byakaron_composer_pick(composer, index), client: controller.client())
        },
        onPage: { next in
            guard let composer = Composer.handle, let controller = active else { return }
            let key = next ? BYAKARON_KEY_PAGE_DOWN : BYAKARON_KEY_PAGE_UP
            controller.apply(byakaron_composer_key(composer, Int32(key), 0, 0), client: controller.client())
        }
    )

    private var hasMarkedText = false
    /// Where the next marked text goes when the client's selection moved away
    /// from the word (see `dropStaleComposition`); nil means the marked range.
    private var pendingReplacement: NSRange?

    override func activateServer(_ sender: Any!) {
        timing.info("activate")
        super.activateServer(sender)
        Self.active = self
        // The composer is shared: drop any word left from another client.
        if let composer = Composer.handle { byakaron_composer_reset(composer) }
        hasMarkedText = false
    }

    override func deactivateServer(_ sender: Any!) {
        flush(client: sender as? (any IMKTextInput))
        Self.candidatePanel.orderOut(nil)
        if Self.active === self { Self.active = nil }
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        flush(client: sender as? (any IMKTextInput))
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown,
            let composer = Composer.handle,
            let client = sender as? (any IMKTextInput)
        else { return false }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            if ms > 30 { timing.notice("slow key: \(ms, format: .fixed(precision: 1)) ms") }
        }
        dropStaleComposition(composer, client: client)
        return apply(ComposerKeys.send(event, to: composer), client: client)
    }

    /// Key equivalents like ⌘A are handled by the app's menu before the input
    /// method sees them, so the word can still be composing while the app has
    /// selected past it. The next key then belongs to that selection, not the
    /// word: Backspace must delete what is selected, and a letter must replace
    /// it. So drop the word (it lies inside the selection) and let the key act
    /// as if nothing were being typed.
    private func dropStaleComposition(_ composer: OpaquePointer, client: any IMKTextInput) {
        guard hasMarkedText else { return }
        let selected = client.selectedRange()
        let marked = client.markedRange()
        guard selected.location != NSNotFound, selected.length > 0 else { return }
        if marked.location != NSNotFound,
            selected.location >= marked.location,
            NSMaxRange(selected) <= NSMaxRange(marked)
        {
            return
        }
        byakaron_composer_reset(composer)
        hasMarkedText = false
        pendingReplacement = selected
        Self.candidatePanel.orderOut(nil)
    }

    // MARK: - Composer glue

    /// Insert the result's commit, redraw, and report whether the key was consumed.
    @discardableResult
    fileprivate func apply(_ result: ByakaronKeyResult, client: (any IMKTextInput)?) -> Bool {
        if let commit = result.commitText { insert(commit, client: client) }
        redraw(client: client)
        return result.handled != 0
    }

    private func flush(client: (any IMKTextInput)?) {
        guard let composer = Composer.handle else { return }
        if let text = byakaron_composer_flush(composer), text.pointee != 0 {
            insert(String(cString: text), client: client)
        }
        redraw(client: client)
    }

    fileprivate func redraw() {
        redraw(client: self.client())
    }

    /// Draw the composer's state: the highlighted candidate as marked text, and
    /// the current page in the candidate panel.
    private func redraw(client: (any IMKTextInput)?) {
        guard let composer = Composer.handle else { return }
        let state = ComposerSnapshot(composer)

        if let client {
            if state.composing {
                showMarkedText(state.preedit, client: client)
            } else if hasMarkedText {
                clearMarkedText(client: client)
            }
        }
        // Only the key right after a stale word replaces the selection.
        pendingReplacement = nil

        guard state.panelVisible, !state.candidates.isEmpty, let client else {
            Self.candidatePanel.orderOut(nil)
            return
        }
        // Where the marked text starts, in screen coordinates.
        var caret = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        if caret == .zero {
            // A client that cannot say where its text is: near the pointer.
            let mouse = NSEvent.mouseLocation
            caret = NSRect(x: mouse.x, y: mouse.y - 20, width: 1, height: 20)
        }
        Self.candidatePanel.show(state, below: caret)
    }

    // MARK: - Drawing

    private func insert(_ text: String, client: (any IMKTextInput)?) {
        hasMarkedText = false
        client?.insertText(
            text as NSString,
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func showMarkedText(_ bangla: String, client: any IMKTextInput) {
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]
        client.setMarkedText(
            NSAttributedString(string: bangla, attributes: attrs),
            selectionRange: NSRange(location: bangla.utf16.count, length: 0),
            replacementRange: pendingReplacement ?? NSRange(location: NSNotFound, length: NSNotFound)
        )
        hasMarkedText = true
    }

    private func clearMarkedText(client: any IMKTextInput) {
        client.setMarkedText(
            "" as NSString,
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        hasMarkedText = false
    }
}
