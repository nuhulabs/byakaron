import Cocoa
import InputMethodKit

/// Byakaron's inline-phonetic input controller.
///
/// Backed by the `ByakaronEngine` (via `ZigTransliterator`): we keep a buffer of
/// raw Latin (Avro phonetic) keystrokes for the in-progress word, re-render the
/// whole buffer to Bangla on every keystroke, and show the result as marked
/// (underlined) text. Dictionary/suffix suggestions from `PhoneticDictionary`
/// are shown in the built-in macOS candidate window (`IMKCandidates`).
///
/// The panel is configured with `IMKCandidatesSendServerKeyEventFirst` so we see
/// navigation/selection keys first; we forward them to the panel ourselves (the
/// implicit "panel first" routing is unreliable for a non-activating IME panel)
/// and let its `candidateSelected(_:)` / `candidateSelectionChanged(_:)`
/// callbacks drive the commit and highlight.
@objc(ByakaronInputController)
class ByakaronInputController: IMKInputController {

    // MARK: - State

    /// Raw Latin keystrokes for the in-progress word.
    private var latinBuffer = ""

    /// Candidates currently shown in the panel. Index 0 is the live phonetic
    /// transliteration (the default commit). Fed to the panel from `candidates(_:)`.
    private var candidateList: [String] = []

    /// The candidate a plain commit (space / Return / focus loss) inserts.
    /// Defaults to the phonetic form and tracks the panel's highlight.
    private var selectedText = ""

    /// Built-in macOS candidate window. Created lazily (it needs the IMKServer)
    /// and reused for the controller's lifetime.
    private var candidatesWindow: IMKCandidates?

    /// Token for the cross-process settings subscription, removed in `deinit`.
    private var settingsObserver: NSObjectProtocol?

    /// Virtual key codes forwarded to the candidate panel while it is visible.
    private static let panelControlKeyCodes: Set<UInt16> = [
        123, 124, 125, 126, // left / right / down / up
        116, 121,           // page up / page down
        36, 76,             // Return / numpad Enter
    ]

    // MARK: - Lifecycle

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        // Load the dictionary/suffix data once, off the main thread.
        PhoneticDictionary.preload()
        // Settings live in the main app (a separate process) which writes the
        // shared suite; observe the cross-process broadcast so a change there
        // drops any in-flight word in this running IME.
        settingsObserver = ByakaronSettings.observeChanges { [weak self] in
            self?.reset()
        }
    }

    deinit {
        if let token = settingsObserver {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    // MARK: - Session lifecycle

    override func deactivateServer(_ sender: Any!) {
        if let client = sender as? (any IMKTextInput) {
            commit(client: client)
        }
        candidatesWindow?.hide()
        super.deactivateServer(sender)
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        candidateList
    }

    // MARK: - Candidate window callbacks

    /// The highlight moved in the candidate window; track it so a plain commit
    /// (space / Return / focus loss) inserts the highlighted candidate.
    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        guard let text = candidateString?.string, !text.isEmpty else { return }
        selectedText = text
    }

    /// The user picked a candidate (Return, a selection number, or a click).
    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let text = candidateString?.string,
              let client = self.client() as (any IMKTextInput)? else { return }
        commitText(text, client: client)
    }

    // MARK: - Key handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event,
              event.type == .keyDown,
              let client = sender as? (any IMKTextInput) else {
            return false
        }

        // Let Cmd/Ctrl shortcuts through, committing any in-progress word first.
        let modifiers = event.modifierFlags
        if modifiers.contains(.command) || modifiers.contains(.control) {
            commit(client: client)
            return false
        }

        let keyCode = event.keyCode

        // Drive the candidate window while it is up.
        if let panel = candidatesWindow, panel.isVisible(), !latinBuffer.isEmpty {
            switch keyCode {
            case 53: // Escape — abandon the word
                reset()
                clearMarkedText(client: client)
                return true

            case 49: // Space — commit the highlighted candidate, pass the space on
                commit(client: client)
                return false

            case 51: // Backspace — fall through to buffer editing below
                break

            default:
                // Forward navigation, Return, and selection (number) keys to the
                // panel. It moves/commits the selection and calls our
                // candidateSelected(_:) / candidateSelectionChanged(_:) callbacks.
                // Returning true keeps the key (notably Return and the digits)
                // from also reaching the host, so picking a candidate never sends
                // the message or types a Bangla digit.
                if panelHandles(event, panel: panel) {
                    forwardToPanel(event, panel: panel)
                    return true
                }
            }
        }

        switch keyCode {
        case 36, 76: // Return / numpad Enter (no panel)
            if !latinBuffer.isEmpty {
                commit(client: client)
                return true
            }
            return false

        case 53: // Escape — drop the buffer, leave host text untouched
            if !latinBuffer.isEmpty {
                reset()
                clearMarkedText(client: client)
                return true
            }
            return false

        case 51: // Backspace
            if !latinBuffer.isEmpty {
                latinBuffer.removeLast()
                if latinBuffer.isEmpty {
                    reset()
                    clearMarkedText(client: client)
                } else {
                    updateComposition(client: client)
                }
                return true
            }
            return false

        case 49: // Space — commit the word, let the space fall through to the host
            if !latinBuffer.isEmpty {
                commit(client: client)
            }
            return false

        default:
            break
        }

        // Printable input: append Avro letters to the buffer, otherwise commit
        // and pass the character through (punctuation the engine ignores, etc.).
        guard let characters = event.characters,
              let scalar = characters.unicodeScalars.first else {
            return false
        }

        if isAvroInputScalar(scalar) {
            latinBuffer.append(Character(scalar))
            updateComposition(client: client)
            return true
        }

        commit(client: client)
        return false
    }

    // MARK: - Composition

    /// Re-transliterate the buffer, show it as marked text, and refresh the
    /// candidate window.
    private func updateComposition(client: any IMKTextInput) {
        let bangla = ZigTransliterator.toBangla(latinBuffer)
        selectedText = bangla
        showMarkedText(bangla, client: client)
        refreshCandidates(client: client)
    }

    /// Recompute candidates from the dictionary and show/hide the panel.
    private func refreshCandidates(client: any IMKTextInput) {
        guard let dict = PhoneticDictionary.shared, !latinBuffer.isEmpty else {
            candidateList = []
            candidatesWindow?.hide()
            return
        }

        candidateList = dict.suggestions(forLatin: latinBuffer)
        // Default commit target is the phonetic form (always index 0).
        selectedText = candidateList.first ?? ZigTransliterator.toBangla(latinBuffer)

        // Only the phonetic form — keep the marked text but skip a one-row panel.
        guard candidateList.count > 1, let panel = candidatesPanel() else {
            candidatesWindow?.hide()
            return
        }

        // Re-read orientation each refresh so a Settings change applies on the
        // next keystroke without restarting the IME.
        panel.setPanelType(panelType())
        panel.update()
        panel.show(IMKCandidatesLocationHint(kIMKLocateCandidatesBelowHint))
    }

    // MARK: - Commit / reset

    /// Commit the current selection (defaults to the phonetic transliteration).
    /// No-op when the buffer is empty.
    func commit(client: any IMKTextInput) {
        guard !latinBuffer.isEmpty else { return }
        let text = selectedText.isEmpty ? ZigTransliterator.toBangla(latinBuffer) : selectedText
        commitText(text, client: client)
    }

    /// Insert `text`, clear the buffer, and tear down the candidate window.
    func commitText(_ text: String, client: any IMKTextInput) {
        reset()
        client.insertText(
            text as NSString,
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    /// Clear the in-progress word and hide the candidate window.
    private func reset() {
        latinBuffer = ""
        selectedText = ""
        candidateList = []
        candidatesWindow?.hide()
    }

    // MARK: - Candidate panel

    /// Whether the visible panel should handle `event`: navigation, Return, or
    /// one of its selection (number) keys.
    private func panelHandles(_ event: NSEvent, panel: IMKCandidates) -> Bool {
        if Self.panelControlKeyCodes.contains(event.keyCode) { return true }
        let selectionKeys = (panel.selectionKeys() as? [NSNumber]) ?? []
        return selectionKeys.contains(NSNumber(value: event.keyCode))
    }

    /// Feed `event` to the candidate window. The public `selectCandidate*` APIs
    /// are no-ops on modern macOS (rdar://34944196), so we route through the same
    /// keyboard entry point IMKServer uses; the panel then fires our callbacks.
    private func forwardToPanel(_ event: NSEvent, panel: IMKCandidates) {
        let selector = Selector(("handleKeyboardEvent:"))
        if panel.responds(to: selector) {
            panel.perform(selector, with: event)
        } else {
            panel.interpretKeyEvents([event])
        }
    }

    /// Map the orientation setting to a built-in candidate panel type.
    private func panelType() -> IMKCandidatePanelType {
        switch ByakaronSettings.candidateOrientation {
        case .vertical:
            return IMKCandidatePanelType(kIMKSingleColumnScrollingCandidatePanel)
        case .horizontal:
            return IMKCandidatePanelType(kIMKSingleRowSteppingCandidatePanel)
        }
    }

    /// Lazily create the candidate window, bound to this controller's IMKServer.
    /// Returns nil if the server isn't available yet.
    private func candidatesPanel() -> IMKCandidates? {
        if let panel = candidatesWindow { return panel }
        guard let server = self.server(),
              let panel = IMKCandidates(server: server, panelType: panelType())
        else { return nil }
        // Route key events to this controller first; we forward navigation and
        // selection to the panel ourselves (implicit panel-first routing is
        // unreliable for a non-activating IME panel).
        panel.setAttributes([
            IMKCandidatesSendServerKeyEventFirst: NSNumber(value: true),
            NSAttributedString.Key.font.rawValue: NSFont.systemFont(ofSize: 16),
        ])
        panel.setDismissesAutomatically(false)
        candidatesWindow = panel
        return panel
    }

    // MARK: - Marked text

    /// Display `bangla` as marked (underlined) text at the insertion point.
    private func showMarkedText(_ bangla: String, client: any IMKTextInput) {
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]
        let attrStr = NSAttributedString(string: bangla, attributes: attrs)
        client.setMarkedText(
            attrStr,
            selectionRange: NSRange(location: bangla.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func clearMarkedText(client: any IMKTextInput) {
        client.setMarkedText(
            "" as NSString,
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    /// Whether a character should feed the Avro buffer. Must stay in sync with the
    /// ASCII symbols handled by `src/transliteration` (e.g. `.` → `।`, `:` → `ঃ`,
    /// `` ` `` is the Avro separator that suppresses auto-conjuncts).
    private func isAvroInputScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) { return true } // A-Z, a-z
        if v >= 0x30 && v <= 0x39 { return true } // 0-9 → Bengali digits
        switch v {
        case 0x2E, 0x2C, 0x60, 0x3A, 0x5E, 0x24: // . , ` : ^ $
            return true
        default:
            return false
        }
    }
}
