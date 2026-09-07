#include "window.h"

#include "layout.h"
#include "setup.h"
#include "spelling.h"
#include "typing.h"

struct _BykWindow {
    AdwApplicationWindow parent_instance;

    BykEngines engines;

    GtkWidget *stack;
    GtkWidget *spell_page;
    GtkWidget *setup_page;
};

G_DEFINE_FINAL_TYPE (BykWindow, byk_window, ADW_TYPE_APPLICATION_WINDOW)

/* ── opening spell.db ────────────────────────────────────────────────────── */

static void
load_spell_in_thread (GTask *task,
                      gpointer source_object,
                      gpointer task_data,
                      GCancellable *cancellable)
{
    (void) source_object;
    (void) task_data;
    (void) cancellable;

    /* byk_spell_new warns and returns NULL when there is no database, which is
     * a supported state rather than an error worth propagating. */
    g_task_return_pointer (task, byk_spell_new (NULL), NULL);
}

static void
on_spell_loaded (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
    BykWindow *self = BYK_WINDOW (user_data);
    BykSpell *spell = g_task_propagate_pointer (G_TASK (result), NULL);
    (void) source_object;

    /*
     * The task holds a reference to the window, so `self` is alive — but the
     * window may already have been disposed and its pages destroyed if it was
     * closed during the load. dispose clears spell_page to say so.
     */
    if (self->spell_page == NULL) {
        byk_spell_free (spell);
        return;
    }

    self->engines.spell = spell;
    byk_spell_page_engine_ready (BYK_SPELL_PAGE (self->spell_page));
}

/*
 * spell.db is a 364MB SQLite file, so opening it on the main thread would hold
 * the first frame hostage. The window paints immediately, the Spelling page
 * shows its loading state, and the handle is installed when it arrives — the
 * same shape as the macOS app's detached load.
 *
 * The handle is created here and used only on the main thread afterwards, so
 * the SQLite connection is never touched from two threads at once.
 */
static void
byk_window_load_spell (BykWindow *self)
{
    GTask *task = g_task_new (self, NULL, on_spell_loaded, self);

    g_task_set_priority (task, G_PRIORITY_DEFAULT);
    g_task_run_in_thread (task, load_spell_in_thread);
    g_object_unref (task);
}

/* ── signals ─────────────────────────────────────────────────────────────── */

/* Adding an input source happens in GNOME Settings, so the status on the Setup
 * page is stale by definition. Re-read it whenever the page comes into view. */
static void
on_visible_page_changed (GObject *object, GParamSpec *pspec, gpointer user_data)
{
    BykWindow *self = BYK_WINDOW (user_data);
    (void) object;
    (void) pspec;

    if (self->setup_page != NULL &&
        adw_view_stack_get_visible_child (ADW_VIEW_STACK (self->stack)) == self->setup_page)
        byk_setup_page_refresh (BYK_SETUP_PAGE (self->setup_page));
}

/* ── construction ────────────────────────────────────────────────────────── */

static GtkWidget *
byk_window_build_menu_button (void)
{
    GMenu *menu = g_menu_new ();

    g_menu_append (menu, "_About Byakaron", "app.about");
    g_menu_append (menu, "_Quit", "app.quit");

    GtkWidget *button = gtk_menu_button_new ();
    gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (button), "open-menu-symbolic");
    gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (button), G_MENU_MODEL (menu));
    gtk_widget_set_tooltip_text (button, "Main Menu");
    g_object_unref (menu);

    return button;
}

static void
byk_window_init (BykWindow *self)
{
    /* Both are cheap enough for the main thread: the transliterator builds its
     * matching trie once, and the lexicon costs ~7ms and is shared process-wide
     * after the first call. Only spell.db is worth a thread. */
    self->engines.transliterator = byk_transliterator_new ();
    self->engines.autocomplete = byk_autocomplete_new ();
    self->engines.spell = NULL;

    if (self->engines.transliterator == NULL)
        g_warning ("byakaron: could not create the transliteration engine");

    self->stack = adw_view_stack_new ();
    self->spell_page = byk_spell_page_new (&self->engines);
    self->setup_page = byk_setup_page_new ();

    adw_view_stack_add_titled_with_icon (ADW_VIEW_STACK (self->stack),
                                         byk_typing_page_new (&self->engines),
                                         "write", "Write", "input-keyboard-symbolic");
    adw_view_stack_add_titled_with_icon (ADW_VIEW_STACK (self->stack),
                                         self->spell_page,
                                         "spelling", "Spelling",
                                         "tools-check-spelling-symbolic");
    adw_view_stack_add_titled_with_icon (ADW_VIEW_STACK (self->stack),
                                         byk_layout_page_new (),
                                         "layout", "Layout", "view-grid-symbolic");
    adw_view_stack_add_titled_with_icon (ADW_VIEW_STACK (self->stack),
                                         self->setup_page,
                                         "setup", "Setup", "emblem-system-symbolic");

    g_signal_connect (self->stack, "notify::visible-child",
                      G_CALLBACK (on_visible_page_changed), self);

    GtkWidget *switcher = adw_view_switcher_new ();
    adw_view_switcher_set_stack (ADW_VIEW_SWITCHER (switcher), ADW_VIEW_STACK (self->stack));
    adw_view_switcher_set_policy (ADW_VIEW_SWITCHER (switcher), ADW_VIEW_SWITCHER_POLICY_WIDE);

    AdwHeaderBar *header = ADW_HEADER_BAR (adw_header_bar_new ());
    adw_header_bar_set_title_widget (header, switcher);
    adw_header_bar_pack_end (header, byk_window_build_menu_button ());

    /* The switcher moves to a bottom bar when the window is too narrow for it
     * to sit in the header. */
    GtkWidget *switcher_bar = adw_view_switcher_bar_new ();
    adw_view_switcher_bar_set_stack (ADW_VIEW_SWITCHER_BAR (switcher_bar),
                                     ADW_VIEW_STACK (self->stack));

    AdwToolbarView *toolbar = ADW_TOOLBAR_VIEW (adw_toolbar_view_new ());
    adw_toolbar_view_add_top_bar (toolbar, GTK_WIDGET (header));
    adw_toolbar_view_set_content (toolbar, self->stack);
    adw_toolbar_view_add_bottom_bar (toolbar, switcher_bar);

    AdwBreakpoint *breakpoint = adw_breakpoint_new (
        adw_breakpoint_condition_parse ("max-width: 550sp"));
    adw_breakpoint_add_setters (breakpoint,
                                G_OBJECT (switcher_bar), "reveal", TRUE,
                                G_OBJECT (header), "title-widget", NULL,
                                NULL);
    adw_application_window_add_breakpoint (ADW_APPLICATION_WINDOW (self), breakpoint);

    adw_application_window_set_content (ADW_APPLICATION_WINDOW (self), GTK_WIDGET (toolbar));

    gtk_window_set_title (GTK_WINDOW (self), "Byakaron");
    gtk_window_set_default_size (GTK_WINDOW (self), 900, 680);
    /* libadwaita needs a declared minimum before it will honour a breakpoint,
     * and it has to be below the 550sp the breakpoint triggers at or the
     * narrow layout could never be reached. */
    gtk_widget_set_size_request (GTK_WIDGET (self), 360, 400);

    byk_window_load_spell (self);
}

static void
byk_window_dispose (GObject *object)
{
    BykWindow *self = BYK_WINDOW (object);

    /* Tells a spell.db load still in flight that its page is gone. */
    self->spell_page = NULL;
    self->setup_page = NULL;

    /* Pages only borrow these, and they are all gone by the time dispose has
     * chained up, so freeing after that is the safe order. */
    G_OBJECT_CLASS (byk_window_parent_class)->dispose (object);

    g_clear_pointer (&self->engines.spell, byk_spell_free);
    g_clear_pointer (&self->engines.autocomplete, byk_autocomplete_free);
    g_clear_pointer (&self->engines.transliterator, byk_transliterator_free);
}

static void
byk_window_class_init (BykWindowClass *klass)
{
    G_OBJECT_CLASS (klass)->dispose = byk_window_dispose;
}

GtkWidget *
byk_window_new (AdwApplication *app)
{
    return g_object_new (BYK_TYPE_WINDOW, "application", app, NULL);
}
