#include "settings.h"

#include "dictionary.h"
#include "learned.h"
#include "prefs.h"
#include "uiutil.h"

struct _BykSettingsPage {
    GtkBox parent_instance;

    BykEngines *engines;
    GSettings *prefs;          /* NULL when the schema is not installed */
    GtkWidget *dict_count;
    GtkWidget *learned_count;
    GtkWidget *learned_clear;
    GCallback dictionary_changed;
    gpointer dictionary_changed_data;
};

G_DEFINE_TYPE (BykSettingsPage, byk_settings_page, GTK_TYPE_BOX)

static GtkWidget *
byk_settings_switch (BykSettingsPage *self, GtkWidget *list, const gchar *key,
                     gboolean invert, const gchar *title, const gchar *subtitle)
{
    GtkWidget *sw = gtk_switch_new ();
    g_settings_bind (self->prefs, key, sw, "active",
                     G_SETTINGS_BIND_DEFAULT |
                     (invert ? G_SETTINGS_BIND_INVERT_BOOLEAN : 0));
    /* Separator between rows, not before the first. */
    const gint rows = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (list), "byk-rows"));
    if (rows > 0)
        byk_box_add (list, gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
    g_object_set_data (G_OBJECT (list), "byk-rows", GINT_TO_POINTER (rows + 1));
    byk_box_add (list, byk_row (NULL, title, subtitle, sw));
    return sw;
}

static GtkWidget *
byk_settings_build_typing (BykSettingsPage *self)
{
    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list (
        "Typing",
        "These apply to the keyboard as soon as you change them.",
        &list);

    if (self->prefs == NULL) {
        GtkWidget *note = gtk_label_new ("Settings are unavailable: Byakaron's settings schema "
                                         "is not installed. Install Byakaron from the Setup page.");
        gtk_label_set_line_wrap (GTK_LABEL (note), TRUE);
        gtk_label_set_xalign (GTK_LABEL (note), 0.0);
        gtk_widget_set_margin_start (note, 12);
        gtk_widget_set_margin_end (note, 12);
        gtk_widget_set_margin_top (note, 10);
        gtk_widget_set_margin_bottom (note, 10);
        byk_css_add (note, "dim-label");
        byk_box_add (list, note);
        return group;
    }

    byk_settings_switch (self, list, BYK_PREFS_PHONETIC_ONLY, TRUE,
                         "Suggest words",
                         "Dictionary completions while typing. Off still transliterates.");
    byk_settings_switch (self, list, BYK_PREFS_SPELLING_SUGGESTIONS, FALSE,
                         "Spelling corrections",
                         "When a word comes out misspelled (sonar → সনার), suggest the correct one (সোনার).");
    byk_settings_switch (self, list, BYK_PREFS_BANGLA_DIGITS, FALSE,
                         "Bangla digits",
                         "0–9 type ০–৯. Off keeps 0–9. Number keys still pick a suggestion while the list is showing.");
    byk_settings_switch (self, list, BYK_PREFS_CANDIDATES_HORIZONTAL, FALSE,
                         "Horizontal suggestion list",
                         "Off shows the suggestions in a column.");
    byk_settings_switch (self, list, BYK_PREFS_QT_CLICK_FIX, FALSE,
                         "Qt apps: type a word once on click",
                         "Ubuntu 20.04 / 22.04, for Qt apps (KDE, Telegram, VLC). "
                         "In other apps a word still being typed is dropped if you click away "
                         "before Space. Not needed on Ubuntu 24.04.");
    return group;
}

void
byk_settings_page_refresh (BykSettingsPage *self)
{
    g_return_if_fail (BYK_IS_SETTINGS_PAGE (self));
    const guint n = byk_userdict_count (self->engines->userdict);
    gchar *text = g_strdup_printf (n == 1 ? "%u saved word" : "%u saved words", n);
    gtk_label_set_text (GTK_LABEL (self->dict_count), text);
    g_free (text);

    /* The keyboard writes this file as it learns: read it fresh each time
     * the page is shown rather than keep a copy that goes stale. */
    BykLearned *learned = byk_learned_new ();
    const guint learned_n = byk_learned_size (learned);
    byk_learned_free (learned);
    text = g_strdup_printf (learned_n == 1 ? "%u learned word" : "%u learned words", learned_n);
    gtk_label_set_text (GTK_LABEL (self->learned_count), text);
    g_free (text);
    gtk_widget_set_sensitive (self->learned_clear, learned_n > 0);
}

static void
on_dictionary_changed (gpointer user_data)
{
    BykSettingsPage *self = BYK_SETTINGS_PAGE (user_data);
    byk_settings_page_refresh (self);
    if (self->dictionary_changed != NULL)
        ((void (*) (gpointer)) self->dictionary_changed) (self->dictionary_changed_data);
}

static void
on_manage_clicked (GtkButton *button, gpointer user_data)
{
    BykSettingsPage *self = BYK_SETTINGS_PAGE (user_data);
    GtkWidget *top = gtk_widget_get_toplevel (GTK_WIDGET (button));
    byk_dictionary_show (GTK_IS_WINDOW (top) ? GTK_WINDOW (top) : NULL,
                         self->engines->userdict, G_CALLBACK (on_dictionary_changed), self);
}

static GtkWidget *
byk_settings_build_dictionary (BykSettingsPage *self)
{
    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list (
        "Personal dictionary",
        "Words you saved as correct. They are never marked as misspelled and the keyboard suggests them.",
        &list);

    GtkWidget *manage = gtk_button_new_with_label ("Manage…");
    g_signal_connect (manage, "clicked", G_CALLBACK (on_manage_clicked), self);
    GtkWidget *row = byk_row (NULL, "", NULL, manage);
    self->dict_count = g_object_get_data (G_OBJECT (row), "byk-title");
    byk_box_add (list, row);
    return group;
}

static void
on_clear_learned_clicked (GtkButton *button, gpointer user_data)
{
    BykSettingsPage *self = BYK_SETTINGS_PAGE (user_data);
    BykLearned *learned = byk_learned_new ();
    GError *error = NULL;
    (void) button;

    if (!byk_learned_clear (learned, &error)) {
        gchar *text = g_strdup_printf ("Could not clear: %s", error->message);
        gtk_label_set_text (GTK_LABEL (self->learned_count), text);
        g_free (text);
        g_error_free (error);
    } else {
        byk_settings_page_refresh (self);
    }
    byk_learned_free (learned);
}

static GtkWidget *
byk_settings_build_learning (BykSettingsPage *self)
{
    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list (
        "Learning",
        "Words you pick from the suggestions move up the list next time. Kept only on this computer.",
        &list);

    if (self->prefs != NULL)
        byk_settings_switch (self, list, BYK_PREFS_LEARN_WORDS, FALSE,
                             "Learn from the words you pick",
                             "The typed word always stays first.");

    self->learned_clear = gtk_button_new_with_label ("Clear");
    gtk_widget_set_tooltip_text (self->learned_clear, "Forget the words learned so far");
    g_signal_connect (self->learned_clear, "clicked", G_CALLBACK (on_clear_learned_clicked), self);
    if (self->prefs != NULL)
        byk_box_add (list, gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
    GtkWidget *row = byk_row (NULL, "", NULL, self->learned_clear);
    self->learned_count = g_object_get_data (G_OBJECT (row), "byk-title");
    byk_box_add (list, row);
    return group;
}

static void
byk_settings_page_init (BykSettingsPage *self)
{
    gtk_orientable_set_orientation (GTK_ORIENTABLE (self), GTK_ORIENTATION_VERTICAL);
}

static void
byk_settings_page_dispose (GObject *object)
{
    BykSettingsPage *self = BYK_SETTINGS_PAGE (object);
    g_clear_object (&self->prefs);
    G_OBJECT_CLASS (byk_settings_page_parent_class)->dispose (object);
}

static void
byk_settings_page_class_init (BykSettingsPageClass *klass)
{
    G_OBJECT_CLASS (klass)->dispose = byk_settings_page_dispose;
}

GtkWidget *
byk_settings_page_new (BykEngines *engines, GCallback on_dictionary_changed_cb, gpointer data)
{
    BykSettingsPage *self = g_object_new (BYK_TYPE_SETTINGS_PAGE, NULL);
    self->engines = engines;
    self->prefs = byk_prefs_try_open ();
    self->dictionary_changed = on_dictionary_changed_cb;
    self->dictionary_changed_data = data;

    GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_halign (column, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request (column, 420, -1);
    gtk_widget_set_margin_bottom (column, 24);
    byk_box_add (column, byk_settings_build_typing (self));
    byk_box_add (column, byk_settings_build_dictionary (self));
    byk_box_add (column, byk_settings_build_learning (self));
    byk_settings_page_refresh (self);

    GtkWidget *scroller = byk_scroller (column, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand (scroller, TRUE);
    byk_box_add_expand (GTK_WIDGET (self), scroller);
    return GTK_WIDGET (self);
}
