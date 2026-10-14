/*
 * BykEngine — IBus shell around Core/composer.c.
 *
 * The word policy (what Space, 1–9, digits, Escape mean) lives in the composer.
 * This file turns those outcomes into IBus preedit / commit / lookup-table
 * calls, including the commit-then-hide order Electron/Monaco requires.
 */
#include "engine.h"

#include <string.h>

#include "composer.h"
#include "corrector.h"
#include "prefs.h"

#define BYK_PAGE_SIZE BYK_COMPOSER_PAGE_SIZE

struct _BykEngine {
    IBusEngine parent_instance;
    BykComposer *composer;
    BykCorrector *corrector; /* spelling corrections; NULL without spell.db */
    IBusLookupTable *table;
    GSettings *prefs; /* NULL when the schema is not installed */
    gboolean table_visible;
    /* How IBus treats the pending word on click / focus-out / reset; see
     * byk_engine_focus_in_id. COMMIT unless the focused client is Qt. */
    IBusPreeditFocusMode preedit_mode;
};

G_DEFINE_TYPE (BykEngine, byk_engine, IBUS_TYPE_ENGINE)

static void
byk_engine_hide_candidates (BykEngine *self)
{
    if (!self->table_visible)
        return;
    self->table_visible = FALSE;
    ibus_engine_hide_lookup_table (IBUS_ENGINE (self));
}

static void
byk_engine_sync_candidates (BykEngine *self)
{
    gchar **words = byk_composer_candidates (self->composer);

    ibus_lookup_table_clear (self->table);

    if (words == NULL || words[0] == NULL) {
        byk_engine_hide_candidates (self);
        return;
    }

    for (gchar **w = words; *w != NULL; w++)
        ibus_lookup_table_append_candidate (self->table,
                                            ibus_text_new_from_string (*w));

    /* The highlight is only drawn once an arrow key has moved it: before that
     * Space and Enter take the typed word, and a highlight would say otherwise. */
    const gint cursor = byk_composer_cursor (self->composer);
    const guint page = byk_composer_page (self->composer);
    ibus_lookup_table_set_cursor_visible (self->table, cursor >= 0);
    ibus_lookup_table_set_cursor_pos (self->table,
                                      cursor >= 0 ? (guint) cursor : page * BYK_PAGE_SIZE);
    self->table_visible = TRUE;
    ibus_engine_update_lookup_table (IBUS_ENGINE (self), self->table, TRUE);
}

static void
byk_engine_sync_preedit (BykEngine *self)
{
    const gchar *latin = byk_composer_latin (self->composer);

    if (latin == NULL || *latin == '\0') {
        ibus_engine_hide_preedit_text (IBUS_ENGINE (self));
        byk_engine_hide_candidates (self);
        return;
    }

    gchar *bangla = byk_composer_preedit (self->composer);
    IBusText *text = ibus_text_new_from_string (bangla);
    ibus_text_append_attribute (text, IBUS_ATTR_TYPE_UNDERLINE,
                                IBUS_ATTR_UNDERLINE_SINGLE, 0, -1);
    const guint cursor = (guint) g_utf8_strlen (bangla, -1);
    /*
     * PREEDIT_COMMIT: on a click, focus-out, reset or source switch, IBus
     * itself commits this text — the GTK module on button-press, before the
     * text view moves its cursor. Committing from the engine instead arrives
     * over D-Bus *after* the move, so typing "ami bangla" and clicking at the
     * start of the line produced বাংলাআমি.
     */
    ibus_engine_update_preedit_text_with_mode (IBUS_ENGINE (self), text, cursor, TRUE,
                                               self->preedit_mode);
    byk_engine_sync_candidates (self);
    g_free (bangla);
}

/*
 * Apply a composer outcome. Returns the IBus process_key_event boolean:
 * TRUE = eaten, FALSE = pass to the application.
 */
static gboolean
byk_engine_apply (BykEngine *self, BykOutcome outcome)
{
    switch (outcome.action) {
    case BYK_ACT_PASS:
        g_free (outcome.commit);
        return FALSE;

    case BYK_ACT_EAT:
        byk_engine_sync_preedit (self);
        g_free (outcome.commit);
        return TRUE;

    case BYK_ACT_COMMIT:
        byk_engine_hide_candidates (self);
        if (outcome.commit != NULL && outcome.commit[0] != '\0')
            ibus_engine_commit_text (IBUS_ENGINE (self),
                                     ibus_text_new_from_string (outcome.commit));
        /* Commit first, then hide: Electron/Monaco treats HidePreeditText as
         * cancel, so the reverse order deletes the word. */
        ibus_engine_hide_preedit_text (IBUS_ENGINE (self));
        g_free (outcome.commit);
        return outcome.pass_key ? FALSE : TRUE;
    }

    g_free (outcome.commit);
    return FALSE;
}

static void
byk_engine_reload_prefs (BykEngine *self)
{
    const gboolean phonetic =
        byk_prefs_boolean (self->prefs, BYK_PREFS_PHONETIC_ONLY, FALSE);
    byk_composer_set_phonetic_only (self->composer, phonetic);

    byk_composer_set_corrections (self->composer,
        byk_prefs_boolean (self->prefs, BYK_PREFS_SPELLING_SUGGESTIONS, TRUE));

    const gboolean horiz =
        byk_prefs_boolean (self->prefs, BYK_PREFS_CANDIDATES_HORIZONTAL, TRUE);
    ibus_lookup_table_set_orientation (self->table,
                                       horiz ? IBUS_ORIENTATION_HORIZONTAL
                                             : IBUS_ORIENTATION_VERTICAL);

    /* Flipping "Suggest words" while a word is pending must hide or refill
     * the list immediately, not on the next key. */
    if (byk_composer_latin (self->composer)[0] != '\0')
        byk_engine_sync_preedit (self);
}

static void
byk_engine_on_prefs (GSettings *settings, gchar *key, gpointer user_data)
{
    (void) settings;
    (void) key;
    byk_engine_reload_prefs (BYK_ENGINE (user_data));
}

static guint
byk_ibus_mods (guint state)
{
    guint mods = 0;
    if (state & IBUS_RELEASE_MASK)
        mods |= BYK_MOD_RELEASE;
    if (state & (IBUS_CONTROL_MASK | IBUS_MOD1_MASK | IBUS_MOD4_MASK |
                 IBUS_SUPER_MASK | IBUS_HYPER_MASK))
        mods |= BYK_MOD_SHORTCUT;
    return mods;
}

static gboolean
byk_engine_process_key_event (IBusEngine *engine,
                              guint       keyval,
                              guint       keycode,
                              guint       state)
{
    (void) keycode;
    return byk_engine_apply (BYK_ENGINE (engine),
                             byk_composer_key (BYK_ENGINE (engine)->composer,
                                               keyval, byk_ibus_mods (state)));
}

static void
byk_engine_page_up (IBusEngine *engine)
{
    byk_engine_apply (BYK_ENGINE (engine),
                      byk_composer_page_delta (BYK_ENGINE (engine)->composer, FALSE));
}

static void
byk_engine_page_down (IBusEngine *engine)
{
    byk_engine_apply (BYK_ENGINE (engine),
                      byk_composer_page_delta (BYK_ENGINE (engine)->composer, TRUE));
}

static void
byk_engine_cursor_up (IBusEngine *engine)
{
    byk_engine_apply (BYK_ENGINE (engine),
                      byk_composer_cursor_move (BYK_ENGINE (engine)->composer, FALSE));
}

static void
byk_engine_cursor_down (IBusEngine *engine)
{
    byk_engine_apply (BYK_ENGINE (engine),
                      byk_composer_cursor_move (BYK_ENGINE (engine)->composer, TRUE));
}

static void
byk_engine_candidate_clicked (IBusEngine *engine,
                              guint       index,
                              guint       button,
                              guint       state)
{
    (void) button;
    (void) state;
    byk_engine_apply (BYK_ENGINE (engine),
                      byk_composer_select (BYK_ENGINE (engine)->composer, index));
}

/*
 * Focus-out / reset / disable: the pending word has already been committed by
 * IBus (PREEDIT_COMMIT, see byk_engine_sync_preedit), so only forget it here.
 * Committing it again would type the word twice.
 */
static void
byk_engine_discard (BykEngine *self)
{
    BykOutcome outcome = byk_composer_flush (self->composer);
    g_free (outcome.commit);
    byk_engine_hide_candidates (self);
}

static void
byk_engine_focus_out (IBusEngine *engine)
{
    byk_engine_discard (BYK_ENGINE (engine));
    IBUS_ENGINE_CLASS (byk_engine_parent_class)->focus_out (engine);
}

static void
byk_engine_reset (IBusEngine *engine)
{
    byk_engine_discard (BYK_ENGINE (engine));
    IBUS_ENGINE_CLASS (byk_engine_parent_class)->reset (engine);
}

/*
 * Qt's IBus module (client name "QIBusInputContext", Qt 5 and 6) commits the
 * pending word itself on a click and then resets, but never tells the daemon
 * so (GTK does, via ClientCommitPreedit). With PREEDIT_COMMIT the daemon
 * commits it as well, and Qt types the word twice: "ami" + click -> আমিআমি.
 * For Qt only, ask IBus to drop it instead; Qt has already kept it.
 *
 * IBus 1.5.27+ only (has-focus-id, see byk_engine_constructor). Older daemons
 * never call this, so every client keeps PREEDIT_COMMIT there.
 *
 * One engine instance follows focus between input contexts, so this runs on
 * every focus change, not once.
 */
static void
byk_engine_focus_in_id (IBusEngine *engine, const gchar *object_path, const gchar *client)
{
    BykEngine *self = BYK_ENGINE (engine);
    (void) object_path;

    const gboolean qt = client != NULL &&
                        (g_str_has_prefix (client, "QIBusInputContext") ||
                         strcmp (client, "Qt") == 0);
    self->preedit_mode = qt ? IBUS_ENGINE_PREEDIT_CLEAR : IBUS_ENGINE_PREEDIT_COMMIT;
}

/* With has-focus-id the daemon calls this *instead of* focus_out. */
static void
byk_engine_focus_out_id (IBusEngine *engine, const gchar *object_path)
{
    (void) object_path;
    byk_engine_discard (BYK_ENGINE (engine));
}

static void
byk_engine_disable (IBusEngine *engine)
{
    byk_engine_discard (BYK_ENGINE (engine));
    IBUS_ENGINE_CLASS (byk_engine_parent_class)->disable (engine);
}

/* Corrections for `word` are cached now. If it is still the word on screen,
 * rebuild the list so they appear without another keystroke. */
static void
byk_engine_on_corrections (const gchar *word, gpointer user_data)
{
    BykEngine *self = BYK_ENGINE (user_data);

    if (self->composer == NULL || byk_composer_latin (self->composer)[0] == '\0')
        return;

    gchar *bangla = byk_composer_preedit (self->composer);
    if (g_strcmp0 (bangla, word) == 0) {
        byk_composer_refresh (self->composer);
        byk_engine_sync_candidates (self);
    }
    g_free (bangla);
}

static void
byk_engine_init (BykEngine *self)
{
    self->composer = byk_composer_new ();
    if (!byk_composer_ready (self->composer))
        g_warning ("byakaron: transliterator unavailable, keys will pass through");

    /* Corrections are looked up on the corrector's worker thread; this runs
     * back on the engine's main loop once a word's are cached. */
    self->corrector = byk_corrector_new (TRUE, byk_engine_on_corrections, self);
    if (self->corrector == NULL)
        g_message ("byakaron: spell.db unavailable, no spelling corrections");
    byk_composer_set_corrector (self->composer, self->corrector);

    self->preedit_mode = IBUS_ENGINE_PREEDIT_COMMIT;
    self->table = ibus_lookup_table_new (BYK_PAGE_SIZE, 0, FALSE, FALSE);
    g_object_ref_sink (self->table);
    self->table_visible = FALSE;

    self->prefs = byk_prefs_try_open ();
    if (self->prefs != NULL)
        g_signal_connect (self->prefs, "changed",
                          G_CALLBACK (byk_engine_on_prefs), self);
    byk_engine_reload_prefs (self);
}

static void
byk_engine_destroy (IBusObject *object)
{
    BykEngine *self = BYK_ENGINE (object);

    g_clear_pointer (&self->composer, byk_composer_free);
    /* After the composer, which borrows it. */
    g_clear_pointer (&self->corrector, byk_corrector_free);
    g_clear_object (&self->table);
    g_clear_object (&self->prefs);

    IBUS_OBJECT_CLASS (byk_engine_parent_class)->destroy (object);
}

/*
 * Turn on has-focus-id so the daemon reports which client is focused
 * (byk_engine_focus_in_id). It is construct-only and the factory builds the
 * engine, so it is set here. Looked up at runtime: libibus before 1.5.27 has
 * no such property, and passing one it does not know would fail construction.
 */
static GObject *
byk_engine_constructor (GType type, guint n_params, GObjectConstructParam *params)
{
    GObjectClass *parent = G_OBJECT_CLASS (byk_engine_parent_class);
    GParamSpec *pspec = g_object_class_find_property (parent, "has-focus-id");

    if (pspec == NULL)
        return parent->constructor (type, n_params, params);

    GValue yes = G_VALUE_INIT;
    g_value_init (&yes, G_TYPE_BOOLEAN);
    g_value_set_boolean (&yes, TRUE);

    GObjectConstructParam *all = g_new (GObjectConstructParam, n_params + 1);
    guint n = 0;
    for (guint i = 0; i < n_params; i++)
        if (params[i].pspec != pspec)
            all[n++] = params[i];
    all[n].pspec = pspec;
    all[n].value = &yes;

    GObject *object = parent->constructor (type, n + 1, all);
    g_free (all);
    g_value_unset (&yes);
    return object;
}

static void
byk_engine_class_init (BykEngineClass *klass)
{
    GObjectClass *gobject_class = G_OBJECT_CLASS (klass);
    IBusObjectClass *object_class = IBUS_OBJECT_CLASS (klass);
    IBusEngineClass *engine_class = IBUS_ENGINE_CLASS (klass);

    gobject_class->constructor = byk_engine_constructor;
    object_class->destroy = byk_engine_destroy;

    engine_class->process_key_event = byk_engine_process_key_event;
    engine_class->focus_out = byk_engine_focus_out;
    engine_class->focus_in_id = byk_engine_focus_in_id;
    engine_class->focus_out_id = byk_engine_focus_out_id;
    engine_class->reset = byk_engine_reset;
    engine_class->disable = byk_engine_disable;
    engine_class->page_up = byk_engine_page_up;
    engine_class->page_down = byk_engine_page_down;
    engine_class->cursor_up = byk_engine_cursor_up;
    engine_class->cursor_down = byk_engine_cursor_down;
    engine_class->candidate_clicked = byk_engine_candidate_clicked;
}
