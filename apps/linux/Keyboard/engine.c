/*
 * BykEngine — IBus shell around libbyakaron's Composer (Core/composer.h).
 *
 * Every keystroke means whatever the composer says (src/Composer.zig, the same
 * on every platform). This file maps X11 keysyms to composer keys, inserts the
 * text it commits, and draws its state: the highlighted candidate as the
 * preedit and the current page as the lookup table. What stays here is IBus
 * glue: the commit-then-hide order Electron/Monaco requires, the preedit focus
 * mode (Qt vs everyone else), and hopping spelling corrections from the
 * composer's worker thread back to the main loop.
 *
 * The lookup table only ever holds the current page: paging, wrapping and
 * learning happen in the composer, so the panel's arrows and clicks are
 * forwarded to it as keys and picks.
 */
#include "engine.h"

#include <string.h>

#include "composer.h"
#include "prefs.h"

struct _BykEngine {
    IBusEngine parent_instance;
    ByakaronComposer *composer; /* NULL if it could not be created: keys pass */
    IBusLookupTable *table;
    GSettings *prefs; /* qt-click-fix; NULL when the schema is not installed */
    gboolean table_visible;
    gboolean preedit_visible;
    gint update_pending; /* atomic: a refresh is queued on the main loop */
    /* How IBus treats the pending word on click / focus-out / reset; see
     * byk_engine_focus_in_id. COMMIT unless the focused client is Qt. */
    IBusPreeditFocusMode preedit_mode;
};

G_DEFINE_TYPE (BykEngine, byk_engine, IBUS_TYPE_ENGINE)

/* TRUE when libibus has has-focus-id (1.5.27+): the daemon then reports the
 * focused app, and Qt is told apart automatically. Set once, in the
 * constructor. */
static gboolean byk_client_names = FALSE;

static void
byk_engine_hide_candidates (BykEngine *self)
{
    if (!self->table_visible)
        return;
    self->table_visible = FALSE;
    ibus_engine_hide_lookup_table (IBUS_ENGINE (self));
}

/* Draw the composer's state: preedit and candidate page. */
static void
byk_engine_redraw (BykEngine *self)
{
    ByakaronComposerState st;
    byakaron_composer_state (self->composer, &st);

    if (st.composing && st.preedit[0] != '\0') {
        IBusText *text = ibus_text_new_from_string (st.preedit);
        ibus_text_append_attribute (text, IBUS_ATTR_TYPE_UNDERLINE,
                                    IBUS_ATTR_UNDERLINE_SINGLE, 0, -1);
        const guint cursor = (guint) g_utf8_strlen (st.preedit, -1);
        /*
         * PREEDIT_COMMIT: on a click, focus-out, reset or source switch, IBus
         * itself commits this text — the GTK module on button-press, before the
         * text view moves its cursor. Committing from the engine instead arrives
         * over D-Bus *after* the move, so typing "ami bangla" and clicking at the
         * start of the line produced বাংলাআমি. The preedit is the highlighted
         * candidate, which is exactly what byakaron_composer_flush commits.
         */
        ibus_engine_update_preedit_text_with_mode (IBUS_ENGINE (self), text, cursor, TRUE,
                                                   self->preedit_mode);
        self->preedit_visible = TRUE;
    } else if (self->preedit_visible) {
        self->preedit_visible = FALSE;
        ibus_engine_hide_preedit_text (IBUS_ENGINE (self));
    }

    if (!st.panel_visible || st.candidate_count == 0) {
        byk_engine_hide_candidates (self);
        return;
    }

    ibus_lookup_table_clear (self->table);
    ibus_lookup_table_set_page_size (self->table, (guint) st.candidate_count);
    for (size_t i = 0; i < st.candidate_count; i++)
        ibus_lookup_table_append_candidate (self->table,
                                            ibus_text_new_from_string (st.candidates[i]));
    ibus_lookup_table_set_cursor_visible (self->table, TRUE);
    ibus_lookup_table_set_cursor_pos (self->table, (guint) st.highlight);
    ibus_lookup_table_set_orientation (self->table,
                                       st.vertical ? IBUS_ORIENTATION_VERTICAL
                                                   : IBUS_ORIENTATION_HORIZONTAL);
    self->table_visible = TRUE;
    ibus_engine_update_lookup_table (IBUS_ENGINE (self), self->table, TRUE);
}

/*
 * Apply a composer result. Returns the IBus process_key_event boolean:
 * TRUE = eaten, FALSE = the application gets the key too.
 */
static gboolean
byk_engine_apply (BykEngine *self, ByakaronKeyResult result)
{
    /* Commit first, then hide (in redraw): Electron/Monaco treats
     * HidePreeditText as cancel, so the reverse order deletes the word. */
    if (result.commit != NULL && result.commit[0] != '\0')
        ibus_engine_commit_text (IBUS_ENGINE (self), ibus_text_new_from_string (result.commit));
    byk_engine_redraw (self);
    return result.handled != 0;
}

static gboolean
byk_engine_send (BykEngine *self, int kind, unsigned int ch, unsigned int mods)
{
    if (self->composer == NULL)
        return FALSE;
    return byk_engine_apply (self, byakaron_composer_key (self->composer, kind, ch, mods));
}

static void
byk_engine_reload_prefs (BykEngine *self)
{
    /*
     * Older IBus (Ubuntu 20.04 / 22.04) cannot say which app is focused, so
     * the user chooses: with "Qt click fix" on, IBus never commits the pending
     * word itself (PREEDIT_CLEAR). Qt then types it once on a click, but GTK
     * apps and browsers drop a word that was still being typed. Newer IBus
     * picks per app in byk_engine_focus_in_id and this switch is ignored.
     */
    if (!byk_client_names)
        self->preedit_mode =
            byk_prefs_boolean (self->prefs, BYK_PREFS_QT_CLICK_FIX, FALSE)
                ? IBUS_ENGINE_PREEDIT_CLEAR : IBUS_ENGINE_PREEDIT_COMMIT;
}

static void
byk_engine_on_prefs (GSettings *settings, gchar *key, gpointer user_data)
{
    (void) settings;
    (void) key;
    byk_engine_reload_prefs (BYK_ENGINE (user_data));
}

static unsigned int
byk_ibus_mods (guint state)
{
    unsigned int mods = 0;
    if (state & IBUS_SHIFT_MASK)
        mods |= BYAKARON_MOD_SHIFT;
    if (state & IBUS_CONTROL_MASK)
        mods |= BYAKARON_MOD_CTRL;
    if (state & IBUS_MOD1_MASK)
        mods |= BYAKARON_MOD_ALT;
    if (state & (IBUS_MOD4_MASK | IBUS_SUPER_MASK | IBUS_HYPER_MASK | IBUS_META_MASK))
        mods |= BYAKARON_MOD_META;
    return mods;
}

static gboolean
byk_engine_process_key_event (IBusEngine *engine,
                              guint       keyval,
                              guint       keycode,
                              guint       state)
{
    (void) keycode;
    /* Released keys must never reach the composer (that would double every
     * character); pure modifier keys are not sent at all. */
    int kind;
    unsigned int ch;
    if ((state & IBUS_RELEASE_MASK) || !byk_keysym_to_key (keyval, &kind, &ch))
        return FALSE;
    return byk_engine_send (BYK_ENGINE (engine), kind, ch, byk_ibus_mods (state));
}

static void
byk_engine_page_up (IBusEngine *engine)
{
    byk_engine_send (BYK_ENGINE (engine), BYAKARON_KEY_PAGE_UP, 0, 0);
}

static void
byk_engine_page_down (IBusEngine *engine)
{
    byk_engine_send (BYK_ENGINE (engine), BYAKARON_KEY_PAGE_DOWN, 0, 0);
}

static void
byk_engine_cursor_up (IBusEngine *engine)
{
    byk_engine_send (BYK_ENGINE (engine), BYAKARON_KEY_UP, 0, 0);
}

static void
byk_engine_cursor_down (IBusEngine *engine)
{
    byk_engine_send (BYK_ENGINE (engine), BYAKARON_KEY_DOWN, 0, 0);
}

static void
byk_engine_candidate_clicked (IBusEngine *engine,
                              guint       index,
                              guint       button,
                              guint       state)
{
    BykEngine *self = BYK_ENGINE (engine);
    (void) button;
    (void) state;
    if (self->composer != NULL)
        byk_engine_apply (self, byakaron_composer_pick (self->composer, index));
}

/*
 * Focus-out / reset / disable: the pending word has already been committed by
 * IBus (PREEDIT_COMMIT, see byk_engine_redraw), or deliberately kept by Qt
 * (PREEDIT_CLEAR), so the composer's flush text is dropped here — inserting it
 * would type the word twice. Flushing rather than resetting still saves a
 * choice Avro learned while the word was typed.
 */
static void
byk_engine_discard (BykEngine *self)
{
    if (self->composer != NULL)
        (void) byakaron_composer_flush (self->composer);
    self->preedit_visible = FALSE; /* the daemon has dealt with it */
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

/* Main loop: corrections the worker looked up have arrived. */
static gboolean
byk_engine_on_update_idle (gpointer user_data)
{
    BykEngine *self = BYK_ENGINE (user_data);
    g_atomic_int_set (&self->update_pending, 0);
    if (self->composer != NULL) {
        byakaron_composer_refresh (self->composer);
        byk_engine_redraw (self);
    }
    return G_SOURCE_REMOVE;
}

/* The composer's worker thread: queue one refresh on the main loop. The idle
 * holds a reference, and finds composer == NULL if the engine went first. */
static void
byk_engine_on_update (void *userdata)
{
    BykEngine *self = BYK_ENGINE (userdata);
    if (g_atomic_int_compare_and_exchange (&self->update_pending, 0, 1))
        g_idle_add_full (G_PRIORITY_DEFAULT, byk_engine_on_update_idle,
                         g_object_ref (self), g_object_unref);
}

static void
byk_engine_init (BykEngine *self)
{
    self->composer = byk_composer_open (TRUE, byk_engine_on_update, self);
    if (self->composer == NULL)
        g_warning ("byakaron: composer unavailable, keys will pass through");

    self->preedit_mode = IBUS_ENGINE_PREEDIT_COMMIT;
    self->table = ibus_lookup_table_new (9, 0, FALSE, FALSE);
    g_object_ref_sink (self->table);

    self->prefs = byk_prefs_try_open ();
    if (self->prefs != NULL)
        g_signal_connect (self->prefs, "changed::" BYK_PREFS_QT_CLICK_FIX,
                          G_CALLBACK (byk_engine_on_prefs), self);
    byk_engine_reload_prefs (self);
}

static void
byk_engine_destroy (IBusObject *object)
{
    BykEngine *self = BYK_ENGINE (object);

    g_clear_pointer (&self->composer, byakaron_composer_destroy);
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
    byk_client_names = pspec != NULL;

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
