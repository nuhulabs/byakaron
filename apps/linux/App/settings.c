#include "settings.h"

#include "dictionary.h"
#include "prefs.h"
#include "uiutil.h"

struct _BykSettingsPage {
    GtkBox parent_instance;

    BykEngines *engines;
    GSettings *prefs;          /* qt-click-fix; NULL when the schema is not installed */
    GtkWidget *dict_count;
    GCallback dictionary_changed;
    gpointer dictionary_changed_data;
};

G_DEFINE_TYPE (BykSettingsPage, byk_settings_page, GTK_TYPE_BOX)

/* Which shared setting a control edits ("byk-field" data on the widget). */
enum {
    BYK_FIELD_SUGGESTIONS,
    BYK_FIELD_SPELLING,
    BYK_FIELD_LEARN,
    BYK_FIELD_DIGITS,
    BYK_FIELD_NEWLINE,
    BYK_FIELD_VERTICAL,
    BYK_FIELD_PER_PAGE,
};

static gboolean *
byk_settings_flag (BykSettings *s, gint field)
{
    switch (field) {
    case BYK_FIELD_SUGGESTIONS: return &s->suggestions;
    case BYK_FIELD_SPELLING:    return &s->spelling_corrections;
    case BYK_FIELD_LEARN:       return &s->learn_choices;
    case BYK_FIELD_DIGITS:      return &s->bangla_digits;
    case BYK_FIELD_NEWLINE:     return &s->newline_on_enter;
    default:                    return &s->vertical;
    }
}

/* Read-modify-write: settings.json may have changed since the page opened. */
static void
byk_settings_store (BykSettingsPage *self, gint field, gint value)
{
    BykSettings s;
    byk_settings_load (self->engines->composer, &s);
    if (field == BYK_FIELD_PER_PAGE)
        s.candidates_per_page = value;
    else
        *byk_settings_flag (&s, field) = value != 0;
    if (!byk_settings_save (self->engines->composer, &s))
        g_warning ("byakaron: could not save settings");
}

static gint
byk_widget_field (gpointer widget)
{
    return GPOINTER_TO_INT (g_object_get_data (G_OBJECT (widget), "byk-field"));
}

static void
on_switch_changed (GtkSwitch *sw, GParamSpec *pspec, gpointer user_data)
{
    (void) pspec;
    byk_settings_store (BYK_SETTINGS_PAGE (user_data), byk_widget_field (sw),
                        gtk_switch_get_active (sw));
}

static void
on_orientation_changed (GtkComboBox *combo, gpointer user_data)
{
    byk_settings_store (BYK_SETTINGS_PAGE (user_data), BYK_FIELD_VERTICAL,
                        gtk_combo_box_get_active (combo) == 1);
}

static void
on_per_page_changed (GtkSpinButton *spin, gpointer user_data)
{
    byk_settings_store (BYK_SETTINGS_PAGE (user_data), BYK_FIELD_PER_PAGE,
                        gtk_spin_button_get_value_as_int (spin));
}

static void
byk_settings_add_row (GtkWidget *list, const gchar *title, const gchar *subtitle,
                      GtkWidget *control)
{
    /* Separator between rows, not before the first. */
    const gint rows = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (list), "byk-rows"));
    if (rows > 0)
        byk_box_add (list, gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
    g_object_set_data (G_OBJECT (list), "byk-rows", GINT_TO_POINTER (rows + 1));
    gtk_widget_set_valign (control, GTK_ALIGN_CENTER);
    byk_box_add (list, byk_row (NULL, title, subtitle, control));
}

static void
byk_settings_switch (BykSettingsPage *self, GtkWidget *list, BykSettings *s, gint field,
                     const gchar *title, const gchar *subtitle)
{
    GtkWidget *sw = gtk_switch_new ();
    gtk_switch_set_active (GTK_SWITCH (sw), *byk_settings_flag (s, field));
    g_object_set_data (G_OBJECT (sw), "byk-field", GINT_TO_POINTER (field));
    g_signal_connect (sw, "notify::active", G_CALLBACK (on_switch_changed), self);
    byk_settings_add_row (list, title, subtitle, sw);
}

static GtkWidget *
byk_settings_build_typing (BykSettingsPage *self)
{
    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list (
        "Typing",
        "The keyboard picks these up from the next word you type.",
        &list);

    BykSettings s;
    byk_settings_load (self->engines->composer, &s);

    byk_settings_switch (self, list, &s, BYK_FIELD_SUGGESTIONS,
                         "Word suggestions",
                         "Avro's dictionary words while typing. Off is phonetic mode: "
                         "everything is typed exactly as transliterated, with no list.");
    byk_settings_switch (self, list, &s, BYK_FIELD_SPELLING,
                         "Spelling corrections",
                         "When a word comes out misspelled (sonar → সনার), suggest the correct one (সোনার).");
    byk_settings_switch (self, list, &s, BYK_FIELD_LEARN,
                         "Remember my choices",
                         "The suggestion you picked for a word is highlighted first next time.");
    byk_settings_switch (self, list, &s, BYK_FIELD_DIGITS,
                         "Bangla digits",
                         "0–9 type ০–৯. Off keeps 0–9. Number keys still pick a suggestion while the list is showing.");
    byk_settings_switch (self, list, &s, BYK_FIELD_NEWLINE,
                         "New line on Enter",
                         "Enter commits the word and also starts a new line. Off commits only.");

    GtkWidget *orientation = gtk_combo_box_text_new ();
    gtk_combo_box_text_append_text (GTK_COMBO_BOX_TEXT (orientation), "Horizontal");
    gtk_combo_box_text_append_text (GTK_COMBO_BOX_TEXT (orientation), "Vertical");
    gtk_combo_box_set_active (GTK_COMBO_BOX (orientation), s.vertical ? 1 : 0);
    g_signal_connect (orientation, "changed", G_CALLBACK (on_orientation_changed), self);
    byk_settings_add_row (list, "Suggestion list", "How the candidates are laid out.", orientation);

    GtkWidget *per_page = gtk_spin_button_new_with_range (3, 9, 1);
    gtk_spin_button_set_value (GTK_SPIN_BUTTON (per_page), s.candidates_per_page);
    g_signal_connect (per_page, "value-changed", G_CALLBACK (on_per_page_changed), self);
    byk_settings_add_row (list, "Suggestions per page", "Page Up / Page Down show the rest.", per_page);

    if (self->engines->composer == NULL)
        gtk_widget_set_sensitive (list, FALSE);
    return group;
}

/* Linux only, and only for IBus older than 1.5.27: kept in GSettings. */
static GtkWidget *
byk_settings_build_compat (BykSettingsPage *self)
{
    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list ("Compatibility", NULL, &list);

    GtkWidget *sw = gtk_switch_new ();
    g_settings_bind (self->prefs, BYK_PREFS_QT_CLICK_FIX, sw, "active", G_SETTINGS_BIND_DEFAULT);
    byk_settings_add_row (list, "Qt apps: type a word once on click",
                          "Ubuntu 20.04 / 22.04, for Qt apps (KDE, Telegram, VLC). "
                          "In other apps a word still being typed is dropped if you click away "
                          "before Space. Not needed on Ubuntu 24.04.",
                          sw);
    return group;
}

void
byk_settings_page_refresh (BykSettingsPage *self)
{
    g_return_if_fail (BYK_IS_SETTINGS_PAGE (self));
    gchar **words = byk_userdict_words (self->engines->composer);
    const guint n = g_strv_length (words);
    g_strfreev (words);
    gchar *text = g_strdup_printf (n == 1 ? "%u saved word" : "%u saved words", n);
    gtk_label_set_text (GTK_LABEL (self->dict_count), text);
    g_free (text);
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
                         self->engines->composer, G_CALLBACK (on_dictionary_changed), self);
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
    byk_settings_page_refresh (self);
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
    if (self->prefs != NULL)
        byk_box_add (column, byk_settings_build_compat (self));
    byk_box_add (column, byk_settings_build_dictionary (self));

    GtkWidget *scroller = byk_scroller (column, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand (scroller, TRUE);
    byk_box_add_expand (GTK_WIDGET (self), scroller);
    return GTK_WIDGET (self);
}
