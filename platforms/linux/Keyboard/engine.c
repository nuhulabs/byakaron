/*
 * BykEngine — IBus engine driving the Zig transliteration core.
 *
 * The model is deliberately simple and mirrors what the macOS IME does: the
 * *latin* text the user typed is the single source of truth. On every keystroke
 * the whole latin buffer is re-transliterated and the preedit is replaced
 * wholesale.
 *
 * Re-running the whole buffer rather than appending incrementally is what makes
 * Bangla come out right: transliteration is contextual, so typing "o" after "b"
 * can change the glyph already on screen, and a conjunct can span several latin
 * characters. Editing the Bangla directly (e.g. deleting one Bangla character on
 * backspace) would split conjuncts and desynchronise the two buffers. The engine
 * is prebuilt and the buffer is one word long, so the re-run is cheap.
 *
 * On top of the preedit the engine offers *candidates*: dictionary words that
 * start with what has been typed so far, shown in the panel's lookup table and
 * picked with the number keys. They come from the lexicon compiled into the
 * core, so no database has to be installed for them to work.
 */
#include "engine.h"

#include <string.h>

#include "autocomplete.h"
#include "transliterator.h"

/*
 * Candidates shown at once. IBus caps a page at 16; nine keeps every entry
 * reachable by a single number key, which is how they are selected.
 */
#define BYK_PAGE_SIZE 9

/*
 * How many candidates to ask the lexicon for. Four pages is enough to be worth
 * paging through without turning the panel into a word list, and the lookup
 * costs about 10µs either way, so the number is a UI choice, not a budget.
 */
#define BYK_CANDIDATE_LIMIT (BYK_PAGE_SIZE * 4)

struct _BykEngine {
    IBusEngine parent_instance;

    /* Raw latin the user typed; the authoritative state. ASCII only, so byte
     * offsets and character offsets coincide (backspace relies on this). */
    GString *latin;

    BykTransliterator *transliterator;
    BykAutoComplete *autocomplete;

    /* Candidates for the current buffer. Owned here (sunk in init) and refilled
     * in place on every keystroke rather than reallocated. */
    IBusLookupTable *table;
    /* Whether the panel is currently showing `table`. The number keys only mean
     * "select" while it is, so this drives key handling and not just the UI. */
    gboolean table_visible;
};

G_DEFINE_TYPE (BykEngine, byk_engine, IBUS_TYPE_ENGINE)

/* Modifiers that mean "this is an application shortcut, not text input". Shift
 * is deliberately absent: Shift+key is how capitals get typed. */
#define BYK_SHORTCUT_MASK \
    (IBUS_CONTROL_MASK | IBUS_MOD1_MASK | IBUS_MOD4_MASK | IBUS_SUPER_MASK | IBUS_HYPER_MASK)

/* ── candidates ──────────────────────────────────────────────────────────── */

/* Take the candidate list off the screen. Safe to call when nothing is shown. */
static void
byk_engine_hide_candidates (BykEngine *self)
{
    if (!self->table_visible)
        return;
    self->table_visible = FALSE;
    ibus_engine_hide_lookup_table (IBUS_ENGINE (self));
}

/*
 * Refill the lookup table with completions of `bangla` and show or hide it.
 *
 * The prefix is the *transliterated* text, not the latin: the lexicon is Bangla,
 * so "ami" only finds আমি once it has been through the engine.
 */
static void
byk_engine_update_candidates (BykEngine *self, const gchar *bangla)
{
    if (self->autocomplete == NULL) {
        byk_engine_hide_candidates (self);
        return;
    }

    gchar **words = byk_autocomplete_prefix (self->autocomplete, bangla,
                                             BYK_CANDIDATE_LIMIT);
    if (words == NULL) {
        /* Lookup failed (already warned). Typing must not stop, so carry on
         * with the preedit alone. */
        byk_engine_hide_candidates (self);
        return;
    }

    ibus_lookup_table_clear (self->table);
    for (gchar **w = words; *w != NULL; w++) {
        /* append_candidate sinks the floating IBusText, so the table owns it. */
        ibus_lookup_table_append_candidate (self->table,
                                            ibus_text_new_from_string (*w));
    }
    g_strfreev (words);

    if (ibus_lookup_table_get_number_of_candidates (self->table) == 0) {
        /* Nothing in the lexicon starts with this — normal while a word is only
         * half typed, and for anything not in the dictionary at all. */
        byk_engine_hide_candidates (self);
        return;
    }

    /* Back to the first page: the previous page number belonged to a different
     * word, and the number keys are read relative to the current page. */
    ibus_lookup_table_set_cursor_pos (self->table, 0);
    self->table_visible = TRUE;
    /* Pass the flag rather than a literal, so what the panel shows and what the
     * number keys believe is shown can never drift apart. */
    ibus_engine_update_lookup_table (IBUS_ENGINE (self), self->table,
                                     self->table_visible);
}

/* First candidate on the page the number keys currently address. */
static guint
byk_engine_page_start (BykEngine *self)
{
    const guint page_size = ibus_lookup_table_get_page_size (self->table);
    return (ibus_lookup_table_get_cursor_pos (self->table) / page_size) * page_size;
}

/* ── preedit helpers ─────────────────────────────────────────────────────── */

/*
 * Push the current buffer to the screen: preedit (underlined, cursor at end)
 * plus the candidates for it. Clearing the buffer hides both instead.
 *
 * One transliteration feeds both surfaces, so the preedit and the candidate list
 * can never disagree about what has been typed.
 */
static void
byk_engine_refresh (BykEngine *self)
{
    if (self->latin->len == 0) {
        ibus_engine_hide_preedit_text (IBUS_ENGINE (self));
        byk_engine_hide_candidates (self);
        return;
    }

    gchar *bangla = byk_transliterator_run (self->transliterator, self->latin->str);
    if (bangla == NULL) {
        /* Transliteration failed; show the raw latin rather than losing input. */
        bangla = g_strdup (self->latin->str);
    }

    IBusText *text = ibus_text_new_from_string (bangla);
    /* end_index is exclusive; -1 means "to the end" and avoids counting chars. */
    ibus_text_append_attribute (text, IBUS_ATTR_TYPE_UNDERLINE,
                                IBUS_ATTR_UNDERLINE_SINGLE, 0, -1);

    /* Cursor sits after the last Bangla character, so cursor_pos is the length
     * in characters (not bytes) of the transliterated text. */
    const guint cursor = (guint) g_utf8_strlen (bangla, -1);

    /* update_preedit_text sinks the floating IBusText; do not unref it. */
    ibus_engine_update_preedit_text (IBUS_ENGINE (self), text, cursor, TRUE);

    byk_engine_update_candidates (self, bangla);
    g_free (bangla);
}

/*
 * Commit the buffer as final text and clear it.
 *
 * `suffix` is appended to the committed Bangla (used for the space that ends a
 * word) and may be NULL. Committing the terminator ourselves rather than letting
 * the key fall through keeps the ordering deterministic: commit_text travels
 * over D-Bus, and a forwarded key is not guaranteed to arrive after it.
 */
static void
byk_engine_commit (BykEngine *self, const gchar *suffix)
{
    if (self->latin->len == 0) {
        if (suffix != NULL && *suffix != '\0')
            ibus_engine_commit_text (IBUS_ENGINE (self),
                                     ibus_text_new_from_string (suffix));
        return;
    }

    gchar *bangla = byk_transliterator_run (self->transliterator, self->latin->str);
    if (bangla == NULL)
        bangla = g_strdup (self->latin->str);

    gchar *final = (suffix != NULL && *suffix != '\0')
        ? g_strconcat (bangla, suffix, NULL)
        : g_strdup (bangla);

    g_string_truncate (self->latin, 0);
    /* Hide the preedit before committing so the text does not briefly appear
     * twice in applications that render preedit and commit independently. */
    ibus_engine_hide_preedit_text (IBUS_ENGINE (self));
    byk_engine_hide_candidates (self);
    ibus_engine_commit_text (IBUS_ENGINE (self), ibus_text_new_from_string (final));

    g_free (final);
    g_free (bangla);
}

/*
 * Commit the candidate at `index` within the page currently on screen.
 *
 * Returns FALSE if the page holds no candidate there — the last page is rarely
 * full, so 7 on a two-entry page has to mean something other than "select".
 */
static gboolean
byk_engine_commit_candidate (BykEngine *self, guint index)
{
    if (!self->table_visible)
        return FALSE;

    const guint pos = byk_engine_page_start (self) + index;
    if (pos >= ibus_lookup_table_get_number_of_candidates (self->table))
        return FALSE;

    IBusText *candidate = ibus_lookup_table_get_candidate (self->table, pos);
    if (candidate == NULL)
        return FALSE;

    /* The table owns `candidate` and gets cleared on the next keystroke, so take
     * a copy before anything else touches it. */
    gchar *word = g_strdup (ibus_text_get_text (candidate));

    g_string_truncate (self->latin, 0);
    ibus_engine_hide_preedit_text (IBUS_ENGINE (self));
    byk_engine_hide_candidates (self);
    /* No trailing space: picking a word is not the same as finishing a sentence,
     * and Space still commits one when the user wants it. */
    ibus_engine_commit_text (IBUS_ENGINE (self), ibus_text_new_from_string (word));

    g_free (word);
    return TRUE;
}

/* Drop the buffer without committing anything. */
static void
byk_engine_clear (BykEngine *self)
{
    if (self->latin->len == 0)
        return;
    g_string_truncate (self->latin, 0);
    ibus_engine_hide_preedit_text (IBUS_ENGINE (self));
    byk_engine_hide_candidates (self);
}

/* ── key handling ────────────────────────────────────────────────────────── */

/*
 * Characters that feed the transliterator: ASCII letters, and only those.
 *
 * The core does map digits and punctuation too (`2024` -> ২০২৪, `.` -> `।`), but
 * buffering them cannot coexist with selecting candidates by number: the same
 * "2" cannot both extend the word and pick the second completion. Number keys
 * win, because a visible list the user is looking at is the more immediate
 * meaning. Bangla numerals therefore need an explicit toggle to reach — a mode
 * with a keybinding, which belongs with the settings app rather than here.
 */
static inline gboolean
byk_is_input_key (guint keyval)
{
    return (keyval >= IBUS_KEY_a && keyval <= IBUS_KEY_z) ||
           (keyval >= IBUS_KEY_A && keyval <= IBUS_KEY_Z);
}

/*
 * 0-based candidate index for a number key, or -1 if it is not one.
 *
 * The keypad digits are separate keyvals, and a keypad "3" is still a "3" to
 * anyone looking at the list.
 */
static inline gint
byk_candidate_index (guint keyval)
{
    if (keyval >= IBUS_KEY_1 && keyval <= IBUS_KEY_9)
        return (gint) (keyval - IBUS_KEY_1);
    if (keyval >= IBUS_KEY_KP_1 && keyval <= IBUS_KEY_KP_9)
        return (gint) (keyval - IBUS_KEY_KP_1);
    return -1;
}

/*
 * Turn the candidate page, and report whether the key was ours.
 *
 * Returns TRUE whenever the list is up, even at the first or last page: Page
 * Down must not scroll the document underneath a candidate list the user is
 * reading through.
 */
static gboolean
byk_engine_page (BykEngine *self, gboolean down)
{
    if (!self->table_visible)
        return FALSE;

    const gboolean moved = down ? ibus_lookup_table_page_down (self->table)
                                : ibus_lookup_table_page_up (self->table);
    if (moved)
        ibus_engine_update_lookup_table (IBUS_ENGINE (self), self->table,
                                         self->table_visible);
    return TRUE;
}

static gboolean
byk_engine_process_key_event (IBusEngine *engine,
                              guint       keyval,
                              guint       keycode,
                              guint       state)
{
    BykEngine *self = BYK_ENGINE (engine);

    (void) keycode; /* keyval is already layout-resolved; raw scancode unused. */

    /* Key releases arrive as separate events. Acting on them would double every
     * character, so they are never ours. */
    if (state & IBUS_RELEASE_MASK)
        return FALSE;

    /* Core failed to load (warned once at init): behave like a plain keyboard
     * rather than swallowing the user's typing. */
    if (self->transliterator == NULL)
        return FALSE;

    /* Ctrl/Alt/Super combinations belong to the application. Commit whatever is
     * pending first so the word is not lost, then let the shortcut through. */
    if (state & BYK_SHORTCUT_MASK) {
        byk_engine_commit (self, NULL);
        return FALSE;
    }

    const gboolean has_preedit = self->latin->len > 0;

    switch (keyval) {
    case IBUS_KEY_BackSpace:
        if (!has_preedit)
            return FALSE; /* Nothing of ours to edit; let the app delete text. */
        /* Remove one *latin* character and re-transliterate. Deleting a Bangla
         * character instead would break conjuncts. */
        g_string_truncate (self->latin, self->latin->len - 1);
        byk_engine_refresh (self);
        return TRUE;

    case IBUS_KEY_Escape:
        if (!has_preedit)
            return FALSE;
        /* Discards the word *and* the candidates in one press. Dismissing only
         * the list first would leave "Escape" meaning two different things
         * depending on state the user cannot see once the list is gone. */
        byk_engine_clear (self);
        return TRUE;

    case IBUS_KEY_space:
        /* Space ends a word: commit the Bangla plus the space in one go. Note it
         * commits what was *typed*, never a candidate — candidates are only ever
         * chosen by number, so no keystroke silently changes the word. */
        if (!has_preedit)
            return FALSE;
        byk_engine_commit (self, " ");
        return TRUE;

    case IBUS_KEY_Return:
    case IBUS_KEY_KP_Enter:
        /* Commit the word but let the application see the Enter itself, so it
         * still sends the message / inserts the newline. */
        if (!has_preedit)
            return FALSE;
        byk_engine_commit (self, NULL);
        return FALSE;

    case IBUS_KEY_Page_Down:
    case IBUS_KEY_KP_Page_Down:
        if (byk_engine_page (self, TRUE))
            return TRUE;
        break;

    case IBUS_KEY_Page_Up:
    case IBUS_KEY_KP_Page_Up:
        if (byk_engine_page (self, FALSE))
            return TRUE;
        break;

    default:
        break;
    }

    /* Number keys pick from the list while it is on screen. Off screen they are
     * ordinary digits, so this cannot swallow one from the application. */
    const gint candidate = byk_candidate_index (keyval);
    if (candidate >= 0 && byk_engine_commit_candidate (self, (guint) candidate))
        return TRUE;

    if (byk_is_input_key (keyval)) {
        g_string_append_c (self->latin, (gchar) keyval);
        byk_engine_refresh (self);
        return TRUE;
    }

    /* Anything else (digits, punctuation, arrows, function keys) terminates the
     * word and is handled by the application. */
    byk_engine_commit (self, NULL);
    return FALSE;
}

/* ── panel-driven candidate control ──────────────────────────────────────── */

/*
 * The panel has its own paging arrows and clickable candidates. Without these
 * the list would only respond to the keyboard, which looks broken once the
 * arrows are on screen.
 */
static void
byk_engine_page_up (IBusEngine *engine)
{
    byk_engine_page (BYK_ENGINE (engine), FALSE);
}

static void
byk_engine_page_down (IBusEngine *engine)
{
    byk_engine_page (BYK_ENGINE (engine), TRUE);
}

static void
byk_engine_candidate_clicked (IBusEngine *engine,
                              guint       index,
                              guint       button,
                              guint       state)
{
    (void) button; (void) state; /* Any click on a candidate means "this one". */

    /* `index` is within the visible page, the same as a number key. */
    byk_engine_commit_candidate (BYK_ENGINE (engine), index);
}

/* ── lifecycle ───────────────────────────────────────────────────────────── */

/*
 * Focus loss, an explicit reset, or the engine being switched away all mean the
 * pending word must not linger: the preedit belongs to a text field we may no
 * longer own. Commit rather than discard so typing is never silently lost.
 */
static void
byk_engine_focus_out (IBusEngine *engine)
{
    byk_engine_commit (BYK_ENGINE (engine), NULL);
    IBUS_ENGINE_CLASS (byk_engine_parent_class)->focus_out (engine);
}

static void
byk_engine_reset (IBusEngine *engine)
{
    byk_engine_commit (BYK_ENGINE (engine), NULL);
    IBUS_ENGINE_CLASS (byk_engine_parent_class)->reset (engine);
}

static void
byk_engine_disable (IBusEngine *engine)
{
    byk_engine_commit (BYK_ENGINE (engine), NULL);
    IBUS_ENGINE_CLASS (byk_engine_parent_class)->disable (engine);
}

static void
byk_engine_init (BykEngine *self)
{
    self->latin = g_string_sized_new (32);
    self->transliterator = byk_transliterator_new ();
    if (self->transliterator == NULL) {
        /* Without the core the engine can only pass keys through; say so once
         * rather than warning on every keystroke. */
        g_warning ("byakaron: transliterator unavailable, keys will pass through");
    }

    /* Candidates are a bonus, not the point: if the lexicon will not open, the
     * engine still transliterates and byk_engine_update_candidates skips. */
    self->autocomplete = byk_autocomplete_new ();
    if (self->autocomplete == NULL)
        g_warning ("byakaron: lexicon unavailable, candidates are disabled");

    /* No visible cursor: candidates are chosen by number, so highlighting one
     * would suggest that Space or Enter would take it, and neither does. The
     * cursor still exists — it is what marks the current page. Pages do not
     * wrap, so Page Down on the last page stays put instead of jumping back. */
    self->table = ibus_lookup_table_new (BYK_PAGE_SIZE, 0, FALSE, FALSE);
    /* Floating on creation like every IBusObject; sink it or the first
     * update_lookup_table would consume the only reference. */
    g_object_ref_sink (self->table);
    self->table_visible = FALSE;
}

static void
byk_engine_destroy (IBusObject *object)
{
    BykEngine *self = BYK_ENGINE (object);

    g_clear_pointer (&self->transliterator, byk_transliterator_free);
    g_clear_pointer (&self->autocomplete, byk_autocomplete_free);
    g_clear_object (&self->table);
    if (self->latin != NULL) {
        g_string_free (self->latin, TRUE);
        self->latin = NULL;
    }

    IBUS_OBJECT_CLASS (byk_engine_parent_class)->destroy (object);
}

static void
byk_engine_class_init (BykEngineClass *klass)
{
    IBusObjectClass *object_class = IBUS_OBJECT_CLASS (klass);
    IBusEngineClass *engine_class = IBUS_ENGINE_CLASS (klass);

    object_class->destroy = byk_engine_destroy;

    engine_class->process_key_event = byk_engine_process_key_event;
    engine_class->focus_out = byk_engine_focus_out;
    engine_class->reset = byk_engine_reset;
    engine_class->disable = byk_engine_disable;
    engine_class->page_up = byk_engine_page_up;
    engine_class->page_down = byk_engine_page_down;
    engine_class->candidate_clicked = byk_engine_candidate_clicked;
}
