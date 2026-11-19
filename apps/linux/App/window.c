#include "window.h"

#include "dictionary.h"
#include "preferences.h"
#include "spelling.h"
#include "updates.h"

struct _BykWindow {
    GtkApplicationWindow parent_instance;

    BykEngines engines;

    GtkWidget *spell_page;
    GtkWidget *preferences;  /* made on first use; destroyed with this window */
    GtkWidget *updates;      /* the "Byakaron X is available" bar */

    gint typing_update;      /* a refresh is queued on the main loop */
};

G_DEFINE_TYPE (BykWindow, byk_window, GTK_TYPE_APPLICATION_WINDOW)

/* ── opening Byakaron.db ────────────────────────────────────────────────────── */

typedef struct {
    BykSpell *spell;
    ByakaronComposer *typing;
} BykLoaded;

/* Main loop: corrections for the word being typed have arrived. */
static gboolean
on_typing_update_idle (gpointer user_data)
{
    BykWindow *self = BYK_WINDOW (user_data);

    g_atomic_int_set (&self->typing_update, 0);
    if (self->spell_page != NULL)
        byk_spell_page_typing_refresh (BYK_SPELL_PAGE (self->spell_page));
    return G_SOURCE_REMOVE;
}

/* The composer's worker thread: queue one refresh on the main loop. */
static void
on_typing_update (void *userdata)
{
    BykWindow *self = BYK_WINDOW (userdata);

    if (g_atomic_int_compare_and_exchange (&self->typing_update, 0, 1))
        g_idle_add_full (G_PRIORITY_DEFAULT, on_typing_update_idle,
                         g_object_ref (self), g_object_unref);
}

static void
load_spell_in_thread (GTask *task,
                      gpointer source_object,
                      gpointer task_data,
                      GCancellable *cancellable)
{
    BykLoaded *loaded = g_new0 (BykLoaded, 1);
    (void) task_data;
    (void) cancellable;

    /* byk_spell_new warns and returns NULL when there is no database, which is
     * a supported state rather than an error worth propagating. */
    loaded->spell = byk_spell_new (NULL);
    loaded->typing = byk_composer_open (TRUE, on_typing_update, source_object);
    g_task_return_pointer (task, loaded, NULL);
}

static void
on_spell_loaded (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
    BykWindow *self = BYK_WINDOW (user_data);
    BykLoaded *loaded = g_task_propagate_pointer (G_TASK (result), NULL);
    BykSpell *spell = loaded->spell;
    ByakaronComposer *typing = loaded->typing;
    (void) source_object;

    g_free (loaded);

    /*
     * The task holds a reference to the window, so `self` is alive — but the
     * window may already have been disposed and its pages destroyed if it was
     * closed during the load. dispose clears spell_page to say so.
     */
    if (self->spell_page == NULL) {
        byk_spell_free (spell);
        g_clear_pointer (&typing, byakaron_composer_destroy);
        return;
    }

    self->engines.spell = spell;
    self->engines.typing = typing;
    byk_spell_page_engine_ready (BYK_SPELL_PAGE (self->spell_page));

    byk_spell_page_focus_editor (BYK_SPELL_PAGE (self->spell_page));
}

/*
 * Byakaron.db is a 364MB SQLite file, so opening it on the main thread would hold
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

/* ── actions ─────────────────────────────────────────────────────────────── */

static void
on_dictionary_changed (gpointer user_data)
{
    BykWindow *self = BYK_WINDOW (user_data);
    if (self->spell_page != NULL)
        byk_spell_page_recheck (BYK_SPELL_PAGE (self->spell_page));
}

static void
on_dictionary_activate (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
    BykWindow *self = BYK_WINDOW (user_data);
    (void) action;
    (void) parameter;
    byk_dictionary_show (GTK_WINDOW (self), self->engines.composer,
                         G_CALLBACK (on_dictionary_changed), self);
}

static void
on_preferences_activate (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
    (void) action;
    byk_window_show_page (BYK_WINDOW (user_data),
                          parameter != NULL ? g_variant_get_string (parameter, NULL) : NULL);
}

static void
on_check_updates_activate (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
    BykWindow *self = BYK_WINDOW (user_data);
    (void) action;
    (void) parameter;
    if (self->updates != NULL)
        byk_updates_check (self->updates, TRUE);
}

static void
byk_window_add_action (BykWindow *self, const gchar *name,
                       const GVariantType *parameter, GCallback activate)
{
    GSimpleAction *action = g_simple_action_new (name, parameter);
    g_signal_connect (action, "activate", activate, self);
    g_action_map_add_action (G_ACTION_MAP (self), G_ACTION (action));
    g_object_unref (action);
}

static void
byk_menu_append (GMenu *menu, const gchar *label, const gchar *action, const gchar *page)
{
    GMenuItem *item = g_menu_item_new (label, NULL);
    if (page != NULL)
        g_menu_item_set_action_and_target_value (item, action, g_variant_new_string (page));
    else
        g_menu_item_set_detailed_action (item, action);
    g_menu_append_item (menu, item);
    g_object_unref (item);
}

/*
 * The primary menu, as GNOME lays one out: what the app does first, then
 * Preferences, Keyboard Shortcuts and About. Quit stays on Ctrl+Q.
 */
static GtkWidget *
byk_window_build_menu_button (BykWindow *self)
{
    byk_window_add_action (self, "preferences", G_VARIANT_TYPE_STRING,
                           G_CALLBACK (on_preferences_activate));
    byk_window_add_action (self, "dictionary", NULL, G_CALLBACK (on_dictionary_activate));
    byk_window_add_action (self, "check-updates", NULL, G_CALLBACK (on_check_updates_activate));

    GMenu *keyboard = g_menu_new ();
    byk_menu_append (keyboard, "Keyboard _Setup", "win.preferences", "setup");
    byk_menu_append (keyboard, "Keyboard _Layout", "win.preferences", "layout");
    byk_menu_append (keyboard, "Personal _Dictionary…", "win.dictionary", NULL);

    GMenu *app_items = g_menu_new ();
    byk_menu_append (app_items, "_Preferences", "win.preferences", "");
    byk_menu_append (app_items, "Check for _Updates", "win.check-updates", NULL);
    byk_menu_append (app_items, "_Keyboard Shortcuts", "win.show-help-overlay", NULL);
    byk_menu_append (app_items, "_About Byakaron", "app.about", NULL);

    GMenu *menu = g_menu_new ();
    g_menu_append_section (menu, NULL, G_MENU_MODEL (keyboard));
    g_menu_append_section (menu, NULL, G_MENU_MODEL (app_items));
    g_object_unref (keyboard);
    g_object_unref (app_items);

    GtkWidget *button = gtk_menu_button_new ();
    gtk_button_set_image (GTK_BUTTON (button),
                          gtk_image_new_from_icon_name ("open-menu-symbolic",
                                                        GTK_ICON_SIZE_BUTTON));
    gtk_widget_set_valign (button, GTK_ALIGN_CENTER);
    gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (button), G_MENU_MODEL (menu));
    gtk_widget_set_tooltip_text (button, "Main Menu");
    g_object_unref (menu);

    return button;
}

/* One shortcut row in the Keyboard Shortcuts window. */
static void
byk_shortcut_add (GtkWidget *group, const gchar *accel, const gchar *title)
{
    GtkWidget *shortcut = g_object_new (GTK_TYPE_SHORTCUTS_SHORTCUT,
                                        "accelerator", accel, "title", title,
                                        "visible", TRUE, NULL);
    gtk_container_add (GTK_CONTAINER (group), shortcut);
}

/* GtkShortcutsWindow is GNOME's standard Ctrl+? sheet; built in code rather
 * than from a .ui resource, since the app ships no GResource bundle. */
static GtkWidget *
byk_window_build_shortcuts (void)
{
    GtkWidget *editor = g_object_new (GTK_TYPE_SHORTCUTS_GROUP, "title", "Editor",
                                      "visible", TRUE, NULL);
    byk_shortcut_add (editor, "<Primary>o", "Open a text file");
    byk_shortcut_add (editor, "<Primary>s", "Save to a file");
    byk_shortcut_add (editor, "<Primary><Shift>c", "Copy the text");
    byk_shortcut_add (editor, "<Primary>t", "Bangla typing on or off");
    byk_shortcut_add (editor, "F9", "Show or hide the issue list");

    GtkWidget *general = g_object_new (GTK_TYPE_SHORTCUTS_GROUP, "title", "General",
                                       "visible", TRUE, NULL);
    byk_shortcut_add (general, "<Primary>comma", "Preferences");
    byk_shortcut_add (general, "<Primary>question", "Keyboard shortcuts");
    byk_shortcut_add (general, "<Primary>q", "Quit");

    GtkWidget *keyboard = g_object_new (GTK_TYPE_SHORTCUTS_GROUP,
                                        "title", "Bangla keyboard (any app)",
                                        "visible", TRUE, NULL);
    byk_shortcut_add (keyboard, "<Super>space", "Switch input source");
    byk_shortcut_add (keyboard, "space", "Commit the highlighted word");
    byk_shortcut_add (keyboard, "Escape", "Discard the word being typed");

    GtkWidget *section = g_object_new (GTK_TYPE_SHORTCUTS_SECTION,
                                       "section-name", "shortcuts", "visible", TRUE, NULL);
    gtk_container_add (GTK_CONTAINER (section), editor);
    gtk_container_add (GTK_CONTAINER (section), general);
    gtk_container_add (GTK_CONTAINER (section), keyboard);

    GtkWidget *window = g_object_new (GTK_TYPE_SHORTCUTS_WINDOW, "modal", TRUE, NULL);
    gtk_container_add (GTK_CONTAINER (window), section);
    return window;
}

/* ── construction ────────────────────────────────────────────────────────── */

static void
byk_window_init (BykWindow *self)
{
    /* Byakaron.db is the only handle worth a thread; the composer opens at once
     * (and moves old GSettings values into settings.json the first time). */
    self->engines.spell = NULL;
    self->engines.composer = byk_composer_open (FALSE, NULL, NULL);

    self->spell_page = byk_spell_page_new (&self->engines);
    gtk_widget_insert_action_group (GTK_WIDGET (self), "spell",
                                    byk_spell_page_get_actions (BYK_SPELL_PAGE (self->spell_page)));

    /* The macOS window title and subtitle; the Windows app's header says the same. */
    GtkWidget *header = gtk_header_bar_new ();
    gtk_header_bar_set_show_close_button (GTK_HEADER_BAR (header), TRUE);
    gtk_header_bar_set_title (GTK_HEADER_BAR (header), "Byakaron");
    gtk_header_bar_set_subtitle (GTK_HEADER_BAR (header), "বাংলা বানান পরীক্ষক");
    gtk_header_bar_pack_end (GTK_HEADER_BAR (header), byk_window_build_menu_button (self));
    byk_spell_page_pack_header (BYK_SPELL_PAGE (self->spell_page), GTK_HEADER_BAR (header));

    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    self->updates = byk_updates_bar_new ();
    gtk_box_pack_start (GTK_BOX (box), self->updates, FALSE, FALSE, 0);
    gtk_box_pack_start (GTK_BOX (box), self->spell_page, TRUE, TRUE, 0);

    gtk_window_set_titlebar (GTK_WINDOW (self), header);
    gtk_container_add (GTK_CONTAINER (self), box);

    gtk_window_set_title (GTK_WINDOW (self), "Byakaron");
    gtk_window_set_default_size (GTK_WINDOW (self), 900, 640);
    gtk_widget_set_size_request (GTK_WIDGET (self), 360, 400);

    gtk_application_window_set_help_overlay (GTK_APPLICATION_WINDOW (self),
                                             GTK_SHORTCUTS_WINDOW (byk_window_build_shortcuts ()));

    gtk_widget_show_all (GTK_WIDGET (self));

    byk_window_load_spell (self);
    byk_updates_check_if_due (self->updates);
}

static void
byk_window_dispose (GObject *object)
{
    BykWindow *self = BYK_WINDOW (object);

    /* Tells a Byakaron.db load still in flight that its page is gone. */
    self->spell_page = NULL;
    self->updates = NULL;
    /* Its pages borrow the engines freed below. */
    g_clear_pointer (&self->preferences, gtk_widget_destroy);

    /* Pages only borrow these, and they are all gone by the time dispose has
     * chained up, so freeing after that is the safe order. */
    G_OBJECT_CLASS (byk_window_parent_class)->dispose (object);

    g_clear_pointer (&self->engines.spell, byk_spell_free);
    g_clear_pointer (&self->engines.composer, byakaron_composer_destroy);
    g_clear_pointer (&self->engines.typing, byakaron_composer_destroy);
}

static void
byk_window_class_init (BykWindowClass *klass)
{
    G_OBJECT_CLASS (klass)->dispose = byk_window_dispose;
}

void
byk_window_show_page (BykWindow *self, const gchar *name)
{
    g_return_if_fail (BYK_IS_WINDOW (self));

    if (name == NULL || g_strcmp0 (name, "spelling") == 0) {
        gtk_window_present (GTK_WINDOW (self));
        return;
    }

    if (self->preferences == NULL)
        self->preferences = byk_preferences_new (GTK_WINDOW (self), &self->engines,
                                                 G_CALLBACK (on_dictionary_changed), self);
    byk_preferences_present (BYK_PREFERENCES (self->preferences), name);
}

GtkWidget *
byk_window_new (GtkApplication *app)
{
    return g_object_new (BYK_TYPE_WINDOW, "application", app, NULL);
}
