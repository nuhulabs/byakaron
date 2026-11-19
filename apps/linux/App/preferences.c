#include "preferences.h"

#include <string.h>

#include "byakaron_strings.h"
#include "dictionary.h"
#include "layout.h"
#include "settings.h"
#include "setup.h"
#include "uiutil.h"

struct _BykPreferences {
    GtkWindow parent_instance;

    GtkWidget *stack;
    GtkWidget *setup_page;
    GtkWidget *dictionary_page;
    GtkWidget *dictionary_view;
};

G_DEFINE_TYPE (BykPreferences, byk_preferences, GTK_TYPE_WINDOW)

/* Adding an input source happens outside this app, and the Spelling page may
 * have saved a word: re-read whichever page comes into view. */
static void
on_visible_page_changed (GObject *object, GParamSpec *pspec, gpointer user_data)
{
    (void) object;
    (void) pspec;
    byk_preferences_refresh (BYK_PREFERENCES (user_data));
}

/* The Spelling page can save a word while this window sits on Dictionary:
 * re-read when the window comes back to the front, not only on a tab switch. */
static void
on_active_changed (GObject *object, GParamSpec *pspec, gpointer user_data)
{
    (void) pspec;
    (void) user_data;
    if (gtk_window_is_active (GTK_WINDOW (object)))
        byk_preferences_refresh (BYK_PREFERENCES (object));
}

/* Closing hides: the window keeps its page and scroll position for next time. */
static gboolean
on_delete (GtkWidget *widget, GdkEvent *event, gpointer user_data)
{
    (void) event;
    (void) user_data;
    gtk_widget_hide (widget);
    return GDK_EVENT_STOP;
}

/* Escape closes a preferences window, as it does GNOME's own. */
static gboolean
on_key_press (GtkWidget *widget, GdkEventKey *event, gpointer user_data)
{
    (void) user_data;
    if (event->keyval == GDK_KEY_Escape &&
        (event->state & gtk_accelerator_get_default_mod_mask ()) == 0) {
        gtk_widget_hide (widget);
        return GDK_EVENT_STOP;
    }
    return GDK_EVENT_PROPAGATE;
}

static void
byk_preferences_init (BykPreferences *self)
{
    (void) self;
}

static void
byk_preferences_class_init (BykPreferencesClass *klass)
{
    (void) klass;
}

GtkWidget *
byk_preferences_new (GtkWindow *parent, BykEngines *engines,
                     GCallback on_dictionary_changed, gpointer data)
{
    BykPreferences *self = g_object_new (BYK_TYPE_PREFERENCES,
                                         "title", "Preferences",
                                         "transient-for", parent,
                                         "destroy-with-parent", TRUE,
                                         "window-position", GTK_WIN_POS_CENTER_ON_PARENT,
                                         "default-width", 720,
                                         "default-height", 620,
                                         NULL);
    gtk_widget_set_size_request (GTK_WIDGET (self), 360, 400);

    self->stack = gtk_stack_new ();
    gtk_stack_set_transition_type (GTK_STACK (self->stack),
                                   GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    self->setup_page = byk_setup_page_new ();

    /* The list fills the tab, with the margins a settings group has. */
    self->dictionary_view = byk_dictionary_view_new (engines->composer,
                                                     on_dictionary_changed, data);
    self->dictionary_page = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_set_border_width (GTK_CONTAINER (self->dictionary_page), 18);
    byk_box_add_expand (self->dictionary_page, self->dictionary_view);

    /* The macOS and Windows Settings tabs, in the same order and with the same
     * names; the stack names are what `byakaron --page=` takes. */
    GtkStack *stack = GTK_STACK (self->stack);
    gtk_stack_add_titled (stack, self->setup_page, "setup", byk_str (BYK_STR_SETUP));
    gtk_stack_add_titled (stack, byk_settings_page_new (engines, "typing"),
                          "typing", byk_str (BYK_STR_TYPING));
    gtk_stack_add_titled (stack, byk_settings_page_new (engines, "candidates"),
                          "candidates", byk_str (BYK_STR_CANDIDATES));
    gtk_stack_add_titled (stack, self->dictionary_page,
                          "dictionary", byk_str (BYK_STR_PERSONAL_DICTIONARY));
    gtk_stack_add_titled (stack, byk_layout_page_new (),
                          "layout", byk_str (BYK_STR_LAYOUT));
    gtk_stack_add_titled (stack, byk_settings_page_new (engines, "updates"),
                          "updates", byk_str (BYK_STR_UPDATES));

    GtkWidget *switcher = gtk_stack_switcher_new ();
    gtk_stack_switcher_set_stack (GTK_STACK_SWITCHER (switcher), GTK_STACK (self->stack));

    GtkWidget *header = gtk_header_bar_new ();
    gtk_header_bar_set_show_close_button (GTK_HEADER_BAR (header), TRUE);
    gtk_header_bar_set_custom_title (GTK_HEADER_BAR (header), switcher);

    gtk_window_set_titlebar (GTK_WINDOW (self), header);
    gtk_container_add (GTK_CONTAINER (self), self->stack);

    g_signal_connect (self->stack, "notify::visible-child",
                      G_CALLBACK (on_visible_page_changed), self);
    g_signal_connect (self, "notify::is-active", G_CALLBACK (on_active_changed), NULL);
    g_signal_connect (self, "delete-event", G_CALLBACK (on_delete), NULL);
    g_signal_connect (self, "key-press-event", G_CALLBACK (on_key_press), NULL);

    gtk_widget_show_all (header);
    gtk_widget_show_all (self->stack);

    return GTK_WIDGET (self);
}

void
byk_preferences_present (BykPreferences *self, const gchar *page)
{
    g_return_if_fail (BYK_IS_PREFERENCES (self));

    /* "settings" was the one tab that held every setting; Typing is where
     * most of them still are. */
    if (page != NULL && strcmp (page, "settings") == 0)
        page = "typing";
    if (page != NULL && page[0] != '\0' &&
        gtk_stack_get_child_by_name (GTK_STACK (self->stack), page) != NULL)
        gtk_stack_set_visible_child_name (GTK_STACK (self->stack), page);

    byk_preferences_refresh (self);
    gtk_window_present (GTK_WINDOW (self));
}

void
byk_preferences_refresh (BykPreferences *self)
{
    g_return_if_fail (BYK_IS_PREFERENCES (self));

    GtkWidget *visible = gtk_stack_get_visible_child (GTK_STACK (self->stack));
    if (visible == self->setup_page)
        byk_setup_page_refresh (BYK_SETUP_PAGE (self->setup_page));
    else if (visible == self->dictionary_page)
        byk_dictionary_view_refresh (self->dictionary_view);
}
