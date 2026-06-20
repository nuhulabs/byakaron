import Foundation

/// Pure-Swift wrapper over libbyakaron's C FFI (the Zig transliteration engine).
///
/// Word-level transliterator: hand it a run of Latin (Avro-phonetic) text and it
/// returns the Bangla rendering. It has no notion of a candidate list or an input
/// session — that richness lives in riti. The IME chooses between this and riti
/// via `ByakaronSettings.useZigTransliteration`.
///
/// The engine builds an internal matching trie that is expensive to construct but
/// cheap to reuse. We therefore create one persistent `ByakaronEngine` per mode
/// (lazily, on first use) and reuse it for the life of the process, rather than
/// rebuilding the trie on every call. Measured: persistent reuse is ~285x faster
/// per word than per-call construction.
final class ZigTransliterator {

    /// Process-wide shared instance. The IME and app each have their own process,
    /// so this is one engine-per-mode per process.
    static let shared = ZigTransliterator()

    /// Serializes access to the C engine handles. The engines are created once
    /// and only read afterwards, but riti-style callers may touch this from more
    /// than one thread, so we guard to stay safe.
    private let lock = NSLock()

    /// Persistent engine handles, created on first use for each mode.
    private var avroEngine: OpaquePointer?
    private var orvaEngine: OpaquePointer?

    private init() {}

    deinit {
        // `shared` lives for the whole process; this mainly matters for any
        // non-singleton instances and for correctness/leak hygiene.
        if let e = avroEngine { byakaron_engine_destroy(e) }
        if let e = orvaEngine { byakaron_engine_destroy(e) }
    }

    // MARK: - Static convenience API (unchanged call sites)

    /// Convert Latin (Avro phonetic) text to Bangla using the shared Zig engine.
    static func toBangla(_ latin: String) -> String {
        shared.transliterate(latin, mode: BYAKARON_MODE_AVRO)
    }

    /// Convert Bangla text back to Latin (reverse / "orva") using the shared engine.
    static func toLatin(_ bangla: String) -> String {
        shared.transliterate(bangla, mode: BYAKARON_MODE_ORVA)
    }

    // MARK: - Instance implementation

    /// Transliterate `text` in `mode`, reusing the persistent engine for that
    /// mode. Returns the input unchanged if the engine can't be built or the FFI
    /// call fails.
    func transliterate(_ text: String, mode: Int32) -> String {
        guard !text.isEmpty else { return text }

        lock.lock()
        defer { lock.unlock() }

        guard let engine = engine(for: mode) else { return text }
        return text.withCString { cstr -> String in
            guard let out = byakaron_engine_transliterate(engine, cstr) else { return text }
            defer { byakaron_string_free(out) }
            return String(cString: out)
        }
    }

    /// Lazily create (once) and return the engine handle for `mode`. Caller must
    /// hold `lock`.
    private func engine(for mode: Int32) -> OpaquePointer? {
        switch mode {
        case BYAKARON_MODE_AVRO:
            if avroEngine == nil { avroEngine = byakaron_engine_create(mode) }
            return avroEngine
        case BYAKARON_MODE_ORVA:
            if orvaEngine == nil { orvaEngine = byakaron_engine_create(mode) }
            return orvaEngine
        default:
            return nil
        }
    }
}
