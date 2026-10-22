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

#include <stddef.h> /* size_t */

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
 * Populates out_ptrs with up to max_out ranked suggestion C-strings.
 * Caller must free each returned string with byakaron_string_free.
 * Returns the count of suggestions written.
 */
size_t byakaron_spell_suggest_list(
    ByakaronSpell *spell,
    const char *word,
    int limit,
    char **out_ptrs,
    size_t max_out
);

/*
 * Context-aware list variant of suggest: ranks with trigram/bigram context
 *   prev2 prev1 [word] next
 * Pass "" for unused neighbors. Fills out_ptrs (free each with
 * byakaron_string_free). Returns count written.
 */
size_t byakaron_spell_suggest_ctx_list(
    ByakaronSpell *spell,
    const char *word,
    const char *prev2,
    const char *prev1,
    const char *next,
    int limit,
    char **out_ptrs,
    size_t max_out
);

/*
 * Prefix completions from spell.db dictionary. JSON string array.
 */
char *byakaron_spell_prefix(ByakaronSpell *spell, const char *prefix, int limit);

size_t byakaron_spell_prefix_list(
    ByakaronSpell *spell,
    const char *prefix,
    int limit,
    char **out_ptrs,
    size_t max_out
);

/*
 * Next-word predictions from spell.db bigrams. JSON string array.
 */
char *byakaron_spell_next_word(ByakaronSpell *spell, const char *previous_word, int limit);

size_t byakaron_spell_next_word_list(
    ByakaronSpell *spell,
    const char *previous_word,
    int limit,
    char **out_ptrs,
    size_t max_out
);

/*
 * Trigram next-word predictions from spell.db trigrams. JSON string array.
 */
char *byakaron_spell_trigram_next_word(
    ByakaronSpell *spell,
    const char *w1,
    const char *w2,
    int limit
);

size_t byakaron_spell_trigram_next_word_list(
    ByakaronSpell *spell,
    const char *w1,
    const char *w2,
    int limit,
    char **out_ptrs,
    size_t max_out
);

/*
 * Tokenize Bangla text into nukta-normalized words. JSON string array.
 * No handle needed.
 */
char *byakaron_tokenize_words(const char *text);

size_t byakaron_tokenize_list(
    const char *text,
    char **out_ptrs,
    size_t max_out
);

/*
 * 1 if the word is in the lexicon, 0 if unknown, -1 on error.
 */
int byakaron_spell_is_correct(ByakaronSpell *spell, const char *word);

/*
 * In-memory Bangla autocomplete (embedded Avro lexicon, no DB).
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

/*
 * List variant of byakaron_ac_prefix. Fills out_ptrs (free each with
 * byakaron_string_free). Returns count written.
 */
size_t byakaron_ac_prefix_list(
    ByakaronAutoComplete *ac,
    const char *prefix,
    int limit,
    char **out_ptrs,
    size_t max_out
);

/*
 * Avro suggestions: OmicronLab Avro's while-typing candidate list for the
 * composed Latin buffer (e.g. "bhalo"), in Avro's order: autocorrect, dictionary
 * words by closeness to the plain transliteration, suffix forms, then the plain
 * transliteration; punctuation around the word is kept on every candidate.
 *
 * Returns JSON {"candidates":["..."],"selected":N} where N is the candidate to
 * highlight (the one last chosen for this input, else 0). Free with
 * byakaron_string_free. NULL on failure.
 */
char *byakaron_ac_suggest(ByakaronAutoComplete *ac, const char *latin);

/*
 * List variant of byakaron_ac_suggest. Fills out_ptrs (free each with
 * byakaron_string_free), sets *selected (if non-NULL) to the index to
 * highlight, and returns the count written.
 */
size_t byakaron_ac_suggest_list(
    ByakaronAutoComplete *ac,
    const char *latin,
    char **out_ptrs,
    size_t max_out,
    int *selected
);

/*
 * Remember candidate (exactly as returned) as the user's choice for latin, so
 * it is highlighted next time. Call when the highlighted candidate changes, as
 * Avro does. Returns 0, or -1 on failure.
 */
int byakaron_ac_select(ByakaronAutoComplete *ac, const char *latin, const char *candidate);

/*
 * Learned choices as a JSON object {"<latin>":"<bangla>"} to persist (free with
 * byakaron_string_free), or NULL on failure. Restore with
 * byakaron_ac_import_selections.
 */
char *byakaron_ac_export_selections(ByakaronAutoComplete *ac);
int byakaron_ac_import_selections(ByakaronAutoComplete *ac, const char *json);

/*
 * Composer: the whole keyboard behind one handle, identical on every platform
 * (OmicronLab Avro behaviour; see src/Composer.zig). A keyboard maps OS key
 * events to byakaron_composer_key, applies the result (insert `commit`, and let
 * the application have the key too when `handled` is 0) and draws
 * byakaron_composer_state. The composer is not thread-safe: use it from one
 * thread.
 */
typedef struct ByakaronComposer ByakaronComposer;

enum {
    BYAKARON_KEY_CHAR = 0,  /* printable ASCII in `ch` */
    BYAKARON_KEY_SPACE = 1,
    BYAKARON_KEY_ENTER = 2,
    BYAKARON_KEY_TAB = 3,
    BYAKARON_KEY_BACKSPACE = 4,
    BYAKARON_KEY_ESCAPE = 5,
    BYAKARON_KEY_UP = 6,
    BYAKARON_KEY_DOWN = 7,
    BYAKARON_KEY_LEFT = 8,
    BYAKARON_KEY_RIGHT = 9,
    BYAKARON_KEY_PAGE_UP = 10,
    BYAKARON_KEY_PAGE_DOWN = 11,
    BYAKARON_KEY_OTHER = 12 /* Home, Delete, function keys, ... */
};

enum {
    BYAKARON_MOD_SHIFT = 1,
    BYAKARON_MOD_CTRL = 2,
    BYAKARON_MOD_ALT = 4,
    BYAKARON_MOD_META = 8 /* Cmd / Super / Win */
};

typedef struct {
    int handled;        /* 1: key consumed; 0: pass it on (after inserting commit) */
    const char *commit; /* text to insert, "" if none; valid until the next call */
} ByakaronKeyResult;

typedef struct {
    int composing;                  /* a word is being typed */
    const char *preedit;            /* inline text: the highlighted candidate */
    int panel_visible;              /* show the candidate panel */
    int vertical;                   /* candidate_orientation setting */
    const char *const *candidates;  /* the current page */
    size_t candidate_count;
    size_t highlight;               /* index within the page */
    size_t page;
    size_t page_count;
} ByakaronComposerState;

typedef void (*ByakaronUpdateFn)(void *userdata);

/*
 * Create a composer keeping settings, learned choices and personal words in
 * data_dir (created on first save). With spell_db (may be NULL), spelling
 * corrections are looked up on a worker thread and on_update(userdata) is
 * called from that thread when they arrive: then call
 * byakaron_composer_refresh on the composer's thread and redraw.
 */
ByakaronComposer *byakaron_composer_create(const char *data_dir, const char *spell_db,
                                           ByakaronUpdateFn on_update, void *userdata);
void byakaron_composer_destroy(ByakaronComposer *composer);

ByakaronKeyResult byakaron_composer_key(ByakaronComposer *composer, int kind,
                                        unsigned int ch, unsigned int modifiers);
/* Choose the index-th candidate of the current page (a click) and commit it. */
ByakaronKeyResult byakaron_composer_pick(ByakaronComposer *composer, size_t index);
/* Commit the word being typed (focus out); returns the text, valid until the next call. */
const char *byakaron_composer_flush(ByakaronComposer *composer);
/* Drop the word being typed. */
void byakaron_composer_reset(ByakaronComposer *composer);
/* Rebuild the candidates after on_update. */
void byakaron_composer_refresh(ByakaronComposer *composer);
/* What to draw; pointers valid until the next call on the composer. */
void byakaron_composer_state(ByakaronComposer *composer, ByakaronComposerState *out);

/*
 * Shared settings as JSON: {"suggestions","spelling_corrections",
 * "learn_choices","bangla_digits","newline_on_enter",
 * "candidate_orientation":"horizontal"|"vertical","candidates_per_page":3..9}.
 * get: free with byakaron_string_free. set: missing fields take defaults;
 * returns 0, or -1 on invalid JSON. Saved to data_dir and picked up by every
 * composer on that directory at its next word.
 */
char *byakaron_settings_get(ByakaronComposer *composer);
int byakaron_settings_set(ByakaronComposer *composer, const char *json);

/* Personal dictionary: get = JSON array (free it); add/remove return 1, 0 or -1. */
char *byakaron_userdict_get(ByakaronComposer *composer);
int byakaron_userdict_add(ByakaronComposer *composer, const char *word);
int byakaron_userdict_remove(ByakaronComposer *composer, const char *word);

#ifdef __cplusplus
}
#endif

#endif /* BYAKARON_H */
