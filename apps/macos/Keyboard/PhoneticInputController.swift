import InputMethodKit

/// The process's one composer (src/Composer.zig): it owns the word being typed,
/// the candidate list, the highlight, paging, learning and the personal
/// dictionary. IMK delivers every event on the main thread, so that is the
/// composer's thread.
private enum Composer {
    static let handle: OpaquePointer? = ByakaronSettings.openComposer(
        spellDB: Bundle.main.url(forResource: "spell", withExtension: "db")?.path,
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

    private var candidatesWindow: IMKCandidates?
    /// The current page of candidates, as the composer last drew it.
    private var pageCandidates: [String] = []
    private var hasMarkedText = false

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.active = self
        // The composer is shared: drop any word left from another client.
        if let composer = Composer.handle { byakaron_composer_reset(composer) }
        hasMarkedText = false
    }

    override func deactivateServer(_ sender: Any!) {
        flush(client: sender as? (any IMKTextInput))
        candidatesWindow?.hide()
        if Self.active === self { Self.active = nil }
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        flush(client: sender as? (any IMKTextInput))
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        pageCandidates
    }

    /// A candidate was clicked. Keys never reach the panel, so this is the mouse.
    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let composer = Composer.handle,
            let text = candidateString?.string,
            let index = pageCandidates.firstIndex(of: text)
        else { return }
        apply(byakaron_composer_pick(composer, index), client: self.client())
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown,
            let composer = Composer.handle,
            let client = sender as? (any IMKTextInput)
        else { return false }
        let (kind, ch) = Self.key(event)
        let result = byakaron_composer_key(composer, kind, ch, Self.modifiers(event.modifierFlags))
        return apply(result, client: client)
    }

    // MARK: - Composer glue

    /// Insert the result's commit, redraw, and report whether the key was consumed.
    @discardableResult
    private func apply(_ result: ByakaronKeyResult, client: (any IMKTextInput)?) -> Bool {
        if let commit = result.commit, commit.pointee != 0 {
            insert(String(cString: commit), client: client)
        }
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
        var state = ByakaronComposerState()
        byakaron_composer_state(composer, &state)

        let preedit = state.preedit.map { String(cString: $0) } ?? ""
        if let client {
            if state.composing != 0 {
                showMarkedText(preedit, client: client)
            } else if hasMarkedText {
                clearMarkedText(client: client)
            }
        }

        pageCandidates = (0..<state.candidate_count).compactMap { i in
            state.candidates?[i].map { String(cString: $0) }
        }
        guard state.panel_visible != 0, !pageCandidates.isEmpty,
            let panel = candidatesPanel(vertical: state.vertical != 0)
        else {
            candidatesWindow?.hide()
            return
        }
        panel.setPanelType(Self.panelType(vertical: state.vertical != 0))
        panel.update()
        panel.show(IMKCandidatesLocationHint(kIMKLocateCandidatesBelowHint))
        panel.selectCandidate(withIdentifier: panel.candidateIdentifier(atLineNumber: Int(state.highlight)))
    }

    /// The ABI key for an event: special keys by key code, printable ASCII by
    /// the characters it types.
    private static func key(_ event: NSEvent) -> (Int32, UInt32) {
        switch event.keyCode {
        case 49: return (Int32(BYAKARON_KEY_SPACE), 0)
        case 36, 76: return (Int32(BYAKARON_KEY_ENTER), 0)  // Return / numpad Enter
        case 48: return (Int32(BYAKARON_KEY_TAB), 0)
        case 51: return (Int32(BYAKARON_KEY_BACKSPACE), 0)  // Delete
        case 53: return (Int32(BYAKARON_KEY_ESCAPE), 0)
        case 126: return (Int32(BYAKARON_KEY_UP), 0)
        case 125: return (Int32(BYAKARON_KEY_DOWN), 0)
        case 123: return (Int32(BYAKARON_KEY_LEFT), 0)
        case 124: return (Int32(BYAKARON_KEY_RIGHT), 0)
        case 116: return (Int32(BYAKARON_KEY_PAGE_UP), 0)
        case 121: return (Int32(BYAKARON_KEY_PAGE_DOWN), 0)
        default: break
        }
        // Option changes `characters` (⌥a → å); the composer passes shortcuts on
        // whatever the character, so fall back to the unmodified one.
        for chars in [event.characters, event.charactersIgnoringModifiers] {
            if let scalar = chars?.unicodeScalars.first, chars?.unicodeScalars.count == 1,
                (0x21...0x7e).contains(scalar.value)
            {
                return (Int32(BYAKARON_KEY_CHAR), scalar.value)
            }
        }
        return (Int32(BYAKARON_KEY_OTHER), 0)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= UInt32(BYAKARON_MOD_SHIFT) }
        if flags.contains(.control) { mods |= UInt32(BYAKARON_MOD_CTRL) }
        if flags.contains(.option) { mods |= UInt32(BYAKARON_MOD_ALT) }
        if flags.contains(.command) { mods |= UInt32(BYAKARON_MOD_META) }
        return mods
    }

    // MARK: - Drawing

    private static func panelType(vertical: Bool) -> IMKCandidatePanelType {
        vertical
            ? IMKCandidatePanelType(kIMKSingleColumnScrollingCandidatePanel)
            : IMKCandidatePanelType(kIMKSingleRowSteppingCandidatePanel)
    }

    private func candidatesPanel(vertical: Bool) -> IMKCandidates? {
        if let panel = candidatesWindow { return panel }
        guard let server = self.server(),
            let panel = IMKCandidates(server: server, panelType: Self.panelType(vertical: vertical))
        else { return nil }
        // Keys come to `handle` first and are all consumed there while the panel
        // shows, so the composer, not the panel, moves the highlight and pages.
        panel.setAttributes([
            IMKCandidatesSendServerKeyEventFirst: NSNumber(value: true),
            NSAttributedString.Key.font.rawValue: NSFont.systemFont(ofSize: 16),
        ])
        panel.setDismissesAutomatically(false)
        candidatesWindow = panel
        return panel
    }

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
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
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
