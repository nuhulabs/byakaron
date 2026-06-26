import Cocoa
import InputMethodKit

/// Experimental inline-phonetic key handling backed by the Zig libbyakaron
/// engine (`ZigTransliterator`). This path is fully independent of riti: there
/// is no engine context, no session object, and no candidate panel. We keep a
/// buffer of raw Latin keystrokes for the current word, re-transliterate the
/// whole buffer on every keystroke, and show the result as marked (underlined)
/// text. The word commits on space/return/escape or any non-Avro input.
///
/// This is a proof of concept to validate the Zig FFI end-to-end; it
/// deliberately trades riti's candidate UX for simplicity.
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

        switch keyCode {
        case 36, 76: // Return / numpad Enter
            if !zigLatinBuffer.isEmpty {
                commitZig(client: client)
                return true
            }
            return false

        case 53: // Escape — drop the buffer, leave host text untouched
            if !zigLatinBuffer.isEmpty {
                zigLatinBuffer = ""
                clearMarkedText(client: client)
                return true
            }
            return false

        case 51: // Backspace
            if !zigLatinBuffer.isEmpty {
                zigLatinBuffer.removeLast()
                if zigLatinBuffer.isEmpty {
                    clearMarkedText(client: client)
                } else {
                    updateZigMarkedText(client: client)
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
            updateZigMarkedText(client: client)
            return true
        }

        // Non-Avro character: flush the current word, then let the host receive
        // the original keypress.
        commitZig(client: client)
        return false
    }

    /// Transliterate the buffer and display it as marked (underlined) text.
    private func updateZigMarkedText(client: any IMKTextInput) {
        let bangla = ZigTransliterator.toBangla(zigLatinBuffer)
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

    /// Commit the transliterated word to the host and reset the buffer. No-op
    /// when the buffer is empty.
    func commitZig(client: any IMKTextInput) {
        guard !zigLatinBuffer.isEmpty else { return }
        let bangla = ZigTransliterator.toBangla(zigLatinBuffer)
        zigLatinBuffer = ""
        client.insertText(
            bangla as NSString,
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
