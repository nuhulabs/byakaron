/*
 * Display-agnostic word composer: latin buffer, Avro transliteration, candidate
 * list, and the key policy both IME front-ends share.
 *
 * IBus, Fcitx5 and the GTK Write page disagree about panels and how text is
 * committed. They agree on what a keystroke *means* — Space commits what was
 * typed, 1–9 pick a candidate while the list is showing, digits otherwise
 * become Bangla numerals, and printable punctuation stays in the latin buffer
 * so Avro can map it (`.` → `।`, `:` → `ঃ`, `$` → `৳`). That policy lives
 * here so the shells cannot drift.
 *
 * Keyvals are X11 keysyms (IBus, GDK and Fcitx5 all use them). Modifier bits
 * are ours, not IBUS_* / FcitxKeyState, so this file includes no IME header.
 */
#ifndef BYAKARON_LINUX_COMPOSER_H
#define BYAKARON_LINUX_COMPOSER_H

#include <glib.h>

G_BEGIN_DECLS

#define BYK_COMPOSER_PAGE_SIZE      9
#define BYK_COMPOSER_CANDIDATE_LIMIT (BYK_COMPOSER_PAGE_SIZE * 4)

/* Released keys must never edit the buffer (that would double every character). */
#define BYK_MOD_RELEASE  (1u << 0)
/* Ctrl / Alt / Super: commit pending text, then let the shortcut through. */
#define BYK_MOD_SHORTCUT (1u << 1)

typedef enum {
    /* Not ours. The front-end returns FALSE / does not filterAndAccept. */
    BYK_ACT_PASS = 0,
    /* Consumed. Front-end should refresh preedit + candidates from accessors. */
    BYK_ACT_EAT,
    /*
     * Commit `commit` (may be NULL for a flush of an empty buffer), then hide
     * the preedit. If `pass_key` is TRUE the original key still goes to the
     * application (Enter, shortcuts).
     */
    BYK_ACT_COMMIT,
} BykAction;

typedef struct {
    BykAction action;
    gchar *commit;     /* owned; caller g_free's. NULL if there is nothing. */
    gboolean pass_key;
} BykOutcome;

typedef struct _BykComposer BykComposer;

BykComposer *byk_composer_new (void);
void byk_composer_free (BykComposer *self);

/* TRUE once the Avro engine opened. Without it every key PASSes. */
gboolean byk_composer_ready (BykComposer *self);

const gchar *byk_composer_latin (BykComposer *self);

/* Current Bangla preedit (latin run through Avro). Newly allocated; g_free. */
gchar *byk_composer_preedit (BykComposer *self);

/*
 * Candidates for the current preedit, or NULL if the list should be hidden.
 * Owned by the composer until the next key; do not free.
 */
gchar **byk_composer_candidates (BykComposer *self);
gboolean byk_composer_table_visible (BykComposer *self);
guint byk_composer_page (BykComposer *self);

/*
 * When TRUE, the dictionary candidate list is hidden; transliteration is
 * unchanged. 1–9 then type Bangla numerals even after a word like "ami".
 * Live: the GTK prefs toggle this while a word is being composed.
 */
void byk_composer_set_phonetic_only (BykComposer *self, gboolean phonetic_only);
gboolean byk_composer_phonetic_only (BykComposer *self);

/*
 * Modifier-only keys (Shift, Caps, AltGr, …) PASS and must not commit. Avro
 * o-kar is capital O, so Shift during `bhalO` / `achO` has to stay in the
 * same word; otherwise the next letter starts a new one (ভালও, আছও).
 */
BykOutcome byk_composer_key (BykComposer *self, guint keyval, guint mods);

/* Panel click: `index` is within the visible page, same as a number key. */
BykOutcome byk_composer_select (BykComposer *self, guint index);

BykOutcome byk_composer_page_delta (BykComposer *self, gboolean down);

/* Focus-out / reset / disable: commit whatever is pending so it is not lost. */
BykOutcome byk_composer_flush (BykComposer *self);

G_END_DECLS

#endif /* BYAKARON_LINUX_COMPOSER_H */
