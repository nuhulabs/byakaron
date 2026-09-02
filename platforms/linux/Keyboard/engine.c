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
 */
#include "engine.h"

#include <string.h>

#include "transliterator.h"

struct _BykEngine {
    IBusEngine parent_instance;

    /* Raw latin the user typed; the authoritative state. ASCII only, so byte
     * offsets and character offsets coincide (backspace relies on this). */
    GString *latin;

    BykTransliterator *transliterator;
};

G_DEFINE_TYPE (BykEngine, byk_engine, IBUS_TYPE_ENGINE)

/* Modifiers that mean "this is an application shortcut, not text input". Shift
 * is deliberately absent: Shift+key is how capitals get typed. */
#define BYK_SHORTCUT_MASK \
    (IBUS_CONTROL_MASK | IBUS_MOD1_MASK | IBUS_MOD4_MASK | IBUS_SUPER_MASK | IBUS_HYPER_MASK)

/* ── preedit helpers ─────────────────────────────────────────────────────── */

/*
 * Push the current buffer to the screen as preedit (underlined, cursor at end).
 * Clearing the buffer hides the preedit instead.
 */
static void
byk_engine_update_preedit (BykEngine *self)
{
    if (self->latin->len == 0) {
        ibus_engine_hide_preedit_text (IBUS_ENGINE (self));
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
    ibus_engine_commit_text (IBUS_ENGINE (self), ibus_text_new_from_string (final));

    g_free (final);
    g_free (bangla);
}

/* Drop the buffer without committing anything. */
static void
byk_engine_clear (BykEngine *self)
{
    if (self->latin->len == 0)
        return;
    g_string_truncate (self->latin, 0);
    ibus_engine_hide_preedit_text (IBUS_ENGINE (self));
}

/* ── key handling ────────────────────────────────────────────────────────── */

/*
 * Characters that feed the transliterator. Only ASCII letters for now: Avro also
 * maps digits and some punctuation, but buffering those would swallow "1" and
 * "." from applications until the word ends, which is more surprising than it is
 * useful before the candidate window exists.
 */
static inline gboolean
byk_is_input_key (guint keyval)
{
    return (keyval >= IBUS_KEY_a && keyval <= IBUS_KEY_z) ||
           (keyval >= IBUS_KEY_A && keyval <= IBUS_KEY_Z);
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
        byk_engine_update_preedit (self);
        return TRUE;

    case IBUS_KEY_Escape:
        if (!has_preedit)
            return FALSE;
        byk_engine_clear (self);
        return TRUE;

    case IBUS_KEY_space:
        /* Space ends a word: commit the Bangla plus the space in one go. */
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

    default:
        break;
    }

    if (byk_is_input_key (keyval)) {
        g_string_append_c (self->latin, (gchar) keyval);
        byk_engine_update_preedit (self);
        return TRUE;
    }

    /* Anything else (digits, punctuation, arrows, function keys) terminates the
     * word and is handled by the application. */
    byk_engine_commit (self, NULL);
    return FALSE;
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
}

static void
byk_engine_destroy (IBusObject *object)
{
    BykEngine *self = BYK_ENGINE (object);

    g_clear_pointer (&self->transliterator, byk_transliterator_free);
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
}
