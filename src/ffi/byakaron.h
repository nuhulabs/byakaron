/*
 * libbyakaron - C FFI header
 *
 * Transliteration engine exports for non-Zig callers (e.g. the macOS Swift
 * app / input method). Implemented in src/ffi/ffi.zig.
 *
 * Memory: every string returned by byakaron_transliterate is heap-allocated and
 * NUL-terminated; the caller owns it and must release it with
 * byakaron_string_free. A NULL return means failure (unknown mode or OOM).
 */
#ifndef BYAKARON_H
#define BYAKARON_H

#ifdef __cplusplus
extern "C" {
#endif

/* Transliteration modes (keep in sync with src/ffi/ffi.zig). */
#define BYAKARON_MODE_AVRO 0 /* Latin -> Bangla (Avro Phonetic) */
#define BYAKARON_MODE_ORVA 1 /* Bangla -> Latin (reverse) */

/*
 * Transliterate a NUL-terminated UTF-8 string using the given mode.
 * Returns a newly allocated NUL-terminated UTF-8 string (free with
 * byakaron_string_free), or NULL on failure.
 */
char *byakaron_transliterate(int mode, const char *text);

/* Free a string returned by byakaron_transliterate. NULL is ignored. */
void byakaron_string_free(char *ptr);

/*
 * Persistent engine handle.
 *
 * byakaron_transliterate() rebuilds its internal matching trie on every call.
 * For repeated use (e.g. an input method firing on each keystroke), create one
 * engine and reuse it: build once, transliterate many times, destroy at the end.
 */
typedef struct ByakaronEngine ByakaronEngine;

/* Create a reusable engine for the given mode, or NULL on failure. */
ByakaronEngine *byakaron_engine_create(int mode);

/*
 * Transliterate with a pre-built engine. Returns a newly allocated
 * NUL-terminated string (free with byakaron_string_free), or NULL.
 */
char *byakaron_engine_transliterate(ByakaronEngine *engine, const char *text);

/* Destroy an engine from byakaron_engine_create. NULL is ignored. */
void byakaron_engine_destroy(ByakaronEngine *engine);

#ifdef __cplusplus
}
#endif

#endif /* BYAKARON_H */
