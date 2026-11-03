import AppKit

/// AppKit glue for the composer C ABI (src/ffi/byakaron.h), compiled into both
/// the keyboard (IMK) and the app's "Avro typing" editor so the two turn key
/// events into composer keys and read its state identically: what you test in
/// the app is what the installed keyboard does.
enum ComposerKeys {
    /// The ABI key for an event: special keys by key code, printable ASCII by
    /// the characters it types.
    static func key(_ event: NSEvent) -> (kind: Int32, ch: UInt32) {
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

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= UInt32(BYAKARON_MOD_SHIFT) }
        if flags.contains(.control) { mods |= UInt32(BYAKARON_MOD_CTRL) }
        if flags.contains(.option) { mods |= UInt32(BYAKARON_MOD_ALT) }
        if flags.contains(.command) { mods |= UInt32(BYAKARON_MOD_META) }
        return mods
    }

    /// Send `event` to `composer`.
    static func send(_ event: NSEvent, to composer: OpaquePointer) -> ByakaronKeyResult {
        let (kind, ch) = key(event)
        return byakaron_composer_key(composer, kind, ch, modifiers(event.modifierFlags))
    }
}

/// What the composer wants drawn, copied out of `ByakaronComposerState` (whose
/// pointers only live until the next call).
struct ComposerSnapshot {
    var composing = false
    /// Inline text: the highlighted candidate.
    var preedit = ""
    var panelVisible = false
    var vertical = false
    /// The current page of candidates.
    var candidates: [String] = []
    /// Index within `candidates`.
    var highlight = 0
    var page = 0
    var pageCount = 0

    init() {}

    init(_ composer: OpaquePointer) {
        var state = ByakaronComposerState()
        byakaron_composer_state(composer, &state)
        composing = state.composing != 0
        preedit = state.preedit.map { String(cString: $0) } ?? ""
        panelVisible = state.panel_visible != 0
        vertical = state.vertical != 0
        candidates = (0..<state.candidate_count).compactMap { i in
            state.candidates?[i].map { String(cString: $0) }
        }
        highlight = Int(state.highlight)
        page = Int(state.page)
        pageCount = Int(state.page_count)
    }
}

extension ByakaronKeyResult {
    /// The text to insert, nil when there is none.
    var commitText: String? {
        guard let commit, commit.pointee != 0 else { return nil }
        return String(cString: commit)
    }
}
