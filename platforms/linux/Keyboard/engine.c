/*
 * BykEngine — IBus shell around Core/composer.c.
 *
 * The word policy (what Space, 1–9, digits, Escape mean) lives in the composer.
 * This file turns those outcomes into IBus preedit / commit / lookup-table
 * calls, including the commit-then-hide order Electron/Monaco requires.
 */
#include "engine.h"

#include "composer.h"
#include "prefs.h"
#include "spell.h"

#define BYK_PAGE_SIZE BYK_COMPOSER_PAGE_SIZE

struct _BykEngine {
    IBusEngine parent_instance;
    BykComposer *composer;
    BykSpell *spell; /* opened so a missing install is visible in the journal */
    IBusLookupTable *table;
    GSettings *prefs; /* NULL when the schema is not installed */
    gboolean table_visible;
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

    const guint page = byk_composer_page (self->composer);
    ibus_lookup_table_set_cursor_pos (self->table, page * BYK_PAGE_SIZE);
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
    ibus_engine_update_preedit_text (IBUS_ENGINE (self), text, cursor, TRUE);
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

static void
byk_engine_focus_out (IBusEngine *engine)
{
    byk_engine_apply (BYK_ENGINE (engine),
                      byk_composer_flush (BYK_ENGINE (engine)->composer));
    IBUS_ENGINE_CLASS (byk_engine_parent_class)->focus_out (engine);
}

static void
byk_engine_reset (IBusEngine *engine)
{
    byk_engine_apply (BYK_ENGINE (engine),
                      byk_composer_flush (BYK_ENGINE (engine)->composer));
    IBUS_ENGINE_CLASS (byk_engine_parent_class)->reset (engine);
}

static void
byk_engine_disable (IBusEngine *engine)
{
    byk_engine_apply (BYK_ENGINE (engine),
                      byk_composer_flush (BYK_ENGINE (engine)->composer));
    IBUS_ENGINE_CLASS (byk_engine_parent_class)->disable (engine);
}

static void
byk_engine_init (BykEngine *self)
{
    self->composer = byk_composer_new ();
    if (!byk_composer_ready (self->composer))
        g_warning ("byakaron: transliterator unavailable, keys will pass through");

    /* Spell-check is the GTK app's job. Opening the file here still proves the
     * install path works; a missing db must not stop typing. */
    self->spell = byk_spell_new (NULL);
    if (self->spell == NULL)
        g_message ("byakaron: spell.db unavailable, spell-check is disabled");

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
    g_clear_pointer (&self->spell, byk_spell_free);
    g_clear_object (&self->table);
    g_clear_object (&self->prefs);

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
