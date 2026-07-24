/*
 * libbyakaron - C FFI header
 *
 * Transliteration + spell-check engine exports for non-Zig callers (e.g. the
 * macOS Swift app / input method). Implemented in src/ffi/ffi.zig.
 *
 * Memory: every string returned by byakaron_transliterate / byakaron_spell_* is
 * heap-allocated and NUL-terminated; the caller owns it and must release it
 * with byakaron_string_free. A NULL return means failure (unknown mode, missing
 * DB, or OOM).
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

/* Free a string returned by byakaron_transliterate / byakaron_spell_*. NULL is ignored. */
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

/*
 * Persistent Bangla spell-check engine backed by spell.db (SymSpell + confusions).
 */
typedef struct ByakaronSpell ByakaronSpell;

/* Open spell.db at db_path. Returns NULL on failure. */
ByakaronSpell *byakaron_spell_create(const char *db_path);

/* Destroy a spell engine from byakaron_spell_create. NULL is ignored. */
void byakaron_spell_destroy(ByakaronSpell *spell);

/*
 * Check text. Returns a newly allocated JSON array of
 * { "token", "known", "suggestions":[{"word","frequency","distance","score"}, ...] }
 * (free with byakaron_string_free), or NULL on failure.
 */
char *byakaron_spell_check(ByakaronSpell *spell, const char *text);

/*
 * Ranked suggestions for a single (presumed misspelled) word.
 * Returns a newly allocated JSON string array (free with byakaron_string_free),
 * or NULL on failure.
 */
char *byakaron_spell_suggest(ByakaronSpell *spell, const char *word, int limit);

/*
 * Like byakaron_spell_suggest, but ranks with trigram/bigram context:
 *   prev2 prev1 [word] next
 * Pass empty strings for unused neighbors.
 */
char *byakaron_spell_suggest_ctx(
    ByakaronSpell *spell,
    const char *word,
    const char *prev2,
    const char *prev1,
    const char *next,
    int limit
);

/*
 * 1 if the word is in the lexicon, 0 if unknown, -1 on error.
 */
int byakaron_spell_is_correct(ByakaronSpell *spell, const char *word);

/*
 * In-memory Bangla autocomplete (dictionary_macos lexicon, no DB).
 */
typedef struct ByakaronAutoComplete ByakaronAutoComplete;

/* Create the embedded Mem autocomplete engine, or NULL on failure. */
ByakaronAutoComplete *byakaron_ac_create(void);

/* Destroy an engine from byakaron_ac_create. NULL is ignored. */
void byakaron_ac_destroy(ByakaronAutoComplete *ac);

/*
 * Prefix completions for a Bangla prefix. Returns a newly allocated JSON
 * string array (free with byakaron_string_free), or NULL on failure.
 */
char *byakaron_ac_prefix(ByakaronAutoComplete *ac, const char *prefix, int limit);

/*
 * 1 if word is in the lexicon, 0 otherwise, -1 on error.
 */
int byakaron_ac_contains(ByakaronAutoComplete *ac, const char *word);

#ifdef __cplusplus
}
#endif

#endif /* BYAKARON_H */
