import Cocoa
import InputMethodKit

/// Inline-phonetic key handling backed by the Zig libbyakaron engine
/// (`ZigTransliterator`). This path is independent of riti: there is no engine
/// context and no riti session. We keep a buffer of raw Latin keystrokes for the
/// current word, re-transliterate the whole buffer on every keystroke, and show
/// the result as marked (underlined) text.
///
/// Suggestions come from the bundled `dictionary.json` / `suffix.json` via
/// `PhoneticDictionary` and are displayed in the built-in macOS candidate window
/// (`IMKCandidates`). We configure the panel with `IMKCandidatesSendServerKeyEventFirst`
/// so navigation/selection keys arrive here first and are then forwarded to the
/// panel deterministically (the implicit "panel first" routing is unreliable for
/// a non-activating IME panel).
extension ByakaronInputController {

    /// Entry point invoked from `handle(_:client:)` when `usingZig` is true.
    /// Returns true if the event was consumed.
    func handleZig(_ event: NSEvent, client: any IMKTextInput) -> Bool {
        let modifiers = event.modifierFlags

        // Let Cmd/Ctrl shortcuts through, committing any in-progress word first.
        if modifiers.contains(.command) || modifiers.contains(.control) {
            commitZig(client: client)
            return false
        }

        let keyCode = event.keyCode

        // While the candidate window is up, drive it from here.
        if let panel = zigCandidatesWindow, panel.isVisible(), !zigLatinBuffer.isEmpty {
            switch keyCode {
            case 126, 125, 123, 124, 116, 121: // up / down / left / right / page up / page down
                panel.interpretKeyEvents([event])
                return true

            case 36, 76: // Return — commit the highlighted candidate
                commitHighlightedZig(panel: panel, client: client)
                return true

            case 53: // Escape — abandon the word
                resetZig()
                clearMarkedText(client: client)
                return true

            case 49: // Space — commit the highlighted candidate, let space through
                commitHighlightedZig(panel: panel, client: client)
                return false

            case 51: // Backspace — fall through to buffer editing below
                break

            default:
                // Number selection (1-9) picks a candidate by its row in the panel.
                if let chars = event.characters, let d = chars.first, d >= "1", d <= "9",
                   selectZigCandidate(byNumber: Int(String(d))! - 1, panel: panel, client: client) {
                    return true
                }
            }
        }

        switch keyCode {
        case 36, 76: // Return / numpad Enter (no panel)
            if !zigLatinBuffer.isEmpty {
                commitZig(client: client)
                return true
            }
            return false

        case 53: // Escape — drop the buffer, leave host text untouched
            if !zigLatinBuffer.isEmpty {
                resetZig()
                clearMarkedText(client: client)
                return true
            }
            return false

        case 51: // Backspace
            if !zigLatinBuffer.isEmpty {
                zigLatinBuffer.removeLast()
                if zigLatinBuffer.isEmpty {
                    resetZig()
                    clearMarkedText(client: client)
                } else {
                    updateZigComposition(client: client)
                }
                return true
            }
            return false

        case 49: // Space — commit the word, let the space fall through to the host
            if !zigLatinBuffer.isEmpty {
                commitZig(client: client)
            }
            return false

        default:
            break
        }

        // Printable input: append Avro letters to the buffer, otherwise commit
        // and pass the character through (digits, punctuation, etc.).
        guard let characters = event.characters,
              let scalar = characters.unicodeScalars.first else {
            return false
        }

        if isAvroInputScalar(scalar) {
            zigLatinBuffer.append(Character(scalar))
            updateZigComposition(client: client)
            return true
        }

        // Non-Avro character: flush the current word, then let the host receive
        // the original keypress.
        commitZig(client: client)
        return false
    }

    /// Re-transliterate the buffer, show it as marked text, and refresh the
    /// candidate window.
    private func updateZigComposition(client: any IMKTextInput) {
        let bangla = ZigTransliterator.toBangla(zigLatinBuffer)
        zigSelected = bangla
        setZigMarkedText(bangla, client: client)
        refreshZigCandidates(client: client)
    }

    /// Recompute candidates from the dictionary and show/hide the built-in
    /// candidate window accordingly.
    private func refreshZigCandidates(client: any IMKTextInput) {
        guard let dict = PhoneticDictionary.shared, !zigLatinBuffer.isEmpty else {
            zigCandidates = []
            zigCandidatesWindow?.hide()
            return
        }

        let list = dict.suggestions(forLatin: zigLatinBuffer)
        zigCandidates = list
        // Default commit target is the phonetic form (always index 0).
        zigSelected = list.first ?? ZigTransliterator.toBangla(zigLatinBuffer)

        // Nothing worth choosing between (only the phonetic form) — keep the
        // marked text but don't clutter the screen with a one-row panel.
        guard list.count > 1, let panel = zigCandidatesPanel() else {
            zigCandidatesWindow?.hide()
            return
        }

        // Re-read orientation each refresh so a Settings change applies on the
        // next keystroke without restarting the IME.
        panel.setPanelType(zigPanelType())
        panel.update()
        panel.show(IMKCandidatesLocationHint(kIMKLocateCandidatesBelowHint))
    }

    /// Commit whatever candidate is currently highlighted in the panel, falling
    /// back to the phonetic form when there is no explicit selection.
    private func commitHighlightedZig(panel: IMKCandidates, client: any IMKTextInput) {
        if let text = panel.selectedCandidateString()?.string, !text.isEmpty {
            commitZigText(text, client: client)
        } else {
            commitZig(client: client)
        }
    }

    /// Select the candidate on visible row `line` (0-based) and commit it.
    /// Returns false if there is no candidate on that row.
    private func selectZigCandidate(byNumber line: Int, panel: IMKCandidates, client: any IMKTextInput) -> Bool {
        let identifier = panel.candidateIdentifier(atLineNumber: line)
        guard identifier != NSNotFound else { return false }
        panel.selectCandidate(withIdentifier: identifier)
        if let text = panel.selectedCandidateString()?.string, !text.isEmpty {
            commitZigText(text, client: client)
            return true
        }
        return false
    }

    /// Map the orientation setting to a built-in candidate panel type.
    private func zigPanelType() -> IMKCandidatePanelType {
        switch ByakaronSettings.candidateOrientation {
        case .vertical:
            return IMKCandidatePanelType(kIMKSingleColumnScrollingCandidatePanel)
        case .horizontal:
            return IMKCandidatePanelType(kIMKSingleRowSteppingCandidatePanel)
        }
    }

    /// Lazily create the built-in candidate window, bound to this controller's
    /// IMKServer. Returns nil if the server isn't available yet.
    private func zigCandidatesPanel() -> IMKCandidates? {
        if let panel = zigCandidatesWindow { return panel }
        guard let server = self.server(),
              let panel = IMKCandidates(server: server, panelType: zigPanelType())
        else { return nil }
        // Route key events to this controller first, then forward navigation to
        // the panel ourselves; the implicit panel-first routing is unreliable.
        panel.setAttributes([
            IMKCandidatesSendServerKeyEventFirst: NSNumber(value: true),
            NSAttributedString.Key.font.rawValue: NSFont.systemFont(ofSize: 16),
        ])
        panel.setDismissesAutomatically(false)
        zigCandidatesWindow = panel
        return panel
    }

    /// Display `bangla` as marked (underlined) text at the insertion point.
    private func setZigMarkedText(_ bangla: String, client: any IMKTextInput) {
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

    /// Commit the current selection (defaults to the phonetic transliteration)
    /// and reset. No-op when the buffer is empty.
    func commitZig(client: any IMKTextInput) {
        guard !zigLatinBuffer.isEmpty else { return }
        let text = zigSelected.isEmpty ? ZigTransliterator.toBangla(zigLatinBuffer) : zigSelected
        commitZigText(text, client: client)
    }

    /// Insert `text`, clear the buffer, and tear down the candidate window.
    func commitZigText(_ text: String, client: any IMKTextInput) {
        resetZig()
        client.insertText(
            text as NSString,
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    /// Clear the in-progress word and hide the candidate window.
    private func resetZig() {
        zigLatinBuffer = ""
        zigSelected = ""
        zigCandidates = []
        zigCandidatesWindow?.hide()
    }

    private func clearMarkedText(client: any IMKTextInput) {
        client.setMarkedText(
            "" as NSString,
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    /// Whether a character should feed the Avro buffer. Must stay in sync with the
    /// ASCII symbols handled by `src/transliteration` (e.g. `.` → `।`, `:` → `ঃ`).
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
