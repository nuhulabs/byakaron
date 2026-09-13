#include "window.h"

#include "layout.h"
#include "setup.h"
#include "spelling.h"
#include "typing.h"

struct _BykWindow {
    GtkApplicationWindow parent_instance;

    BykEngines engines;

    GtkWidget *stack;
    GtkWidget *spell_page;
    GtkWidget *setup_page;
};

G_DEFINE_TYPE (BykWindow, byk_window, GTK_TYPE_APPLICATION_WINDOW)

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
        gtk_stack_get_visible_child (GTK_STACK (self->stack)) == self->setup_page)
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
    gtk_button_set_image (GTK_BUTTON (button),
                          gtk_image_new_from_icon_name ("open-menu-symbolic",
                                                        GTK_ICON_SIZE_BUTTON));
    gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (button), G_MENU_MODEL (menu));
    gtk_widget_set_tooltip_text (button, "Main Menu");
    g_object_unref (menu);

    return button;
}

static void
byk_stack_add (GtkStack *stack,
               GtkWidget *child,
               const gchar *name,
               const gchar *title,
               const gchar *icon)
{
    gtk_stack_add_titled (stack, child, name, title);
    gtk_container_child_set (GTK_CONTAINER (stack), child, "icon-name", icon, NULL);
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

    self->stack = gtk_stack_new ();
    gtk_stack_set_transition_type (GTK_STACK (self->stack),
                                   GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT);
    self->spell_page = byk_spell_page_new (&self->engines);
    self->setup_page = byk_setup_page_new ();

    byk_stack_add (GTK_STACK (self->stack), byk_typing_page_new (),
                   "write", "Write", "input-keyboard-symbolic");
    byk_stack_add (GTK_STACK (self->stack), self->spell_page,
                   "spelling", "Spelling", "tools-check-spelling-symbolic");
    byk_stack_add (GTK_STACK (self->stack), byk_layout_page_new (),
                   "layout", "Layout", "view-grid-symbolic");
    byk_stack_add (GTK_STACK (self->stack), self->setup_page,
                   "setup", "Setup", "emblem-system-symbolic");

    g_signal_connect (self->stack, "notify::visible-child",
                      G_CALLBACK (on_visible_page_changed), self);

    GtkWidget *switcher = gtk_stack_switcher_new ();
    gtk_stack_switcher_set_stack (GTK_STACK_SWITCHER (switcher), GTK_STACK (self->stack));

    GtkWidget *header = gtk_header_bar_new ();
    gtk_header_bar_set_show_close_button (GTK_HEADER_BAR (header), TRUE);
    gtk_header_bar_set_custom_title (GTK_HEADER_BAR (header), switcher);
    gtk_header_bar_pack_end (GTK_HEADER_BAR (header), byk_window_build_menu_button ());

    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_pack_start (GTK_BOX (box), self->stack, TRUE, TRUE, 0);

    gtk_window_set_titlebar (GTK_WINDOW (self), header);
    gtk_container_add (GTK_CONTAINER (self), box);

    gtk_window_set_title (GTK_WINDOW (self), "Byakaron");
    gtk_window_set_default_size (GTK_WINDOW (self), 900, 680);
    gtk_widget_set_size_request (GTK_WIDGET (self), 360, 400);

    gtk_widget_show_all (GTK_WIDGET (self));

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
byk_window_new (GtkApplication *app)
{
    return g_object_new (BYK_TYPE_WINDOW, "application", app, NULL);
}
