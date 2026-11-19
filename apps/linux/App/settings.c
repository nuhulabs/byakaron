#include "settings.h"

#include <locale.h>

#include "prefs.h"
#include "uiutil.h"

struct _BykSettingsPage {
    GtkBox parent_instance;

    BykEngines *engines;
    GSettings *prefs;          /* qt-click-fix; NULL when the schema is not installed */
};

G_DEFINE_TYPE (BykSettingsPage, byk_settings_page, GTK_TYPE_BOX)

/* The key of the shared setting a control edits ("byk-key" data, static). */
static void
byk_settings_store (gpointer widget, gpointer user_data, gint value)
{
    BykSettingsPage *self = BYK_SETTINGS_PAGE (user_data);
    const gchar *key = g_object_get_data (G_OBJECT (widget), "byk-key");
    if (byakaron_setting_set (self->engines->composer, key, value) != 0)
        g_warning ("byakaron: could not save setting %s", key);
}

static void
on_switch_changed (GtkSwitch *sw, GParamSpec *pspec, gpointer user_data)
{
    (void) pspec;
    byk_settings_store (sw, user_data, gtk_switch_get_active (sw));
}

static void
on_choice_changed (GtkComboBox *combo, gpointer user_data)
{
    byk_settings_store (combo, user_data, gtk_combo_box_get_active (combo));
}

static void
on_number_changed (GtkSpinButton *spin, gpointer user_data)
{
    byk_settings_store (spin, user_data, gtk_spin_button_get_value_as_int (spin));
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

/* The POSIX message locale, as byk_str picks it. */
static const gchar *
byk_settings_lang (void)
{
    const gchar *lang = g_getenv ("LANGUAGE");
    if (lang == NULL || *lang == '\0')
        lang = setlocale (LC_MESSAGES, NULL);
    return lang;
}

/* The control for one manifest field, set to its current value. */
static GtkWidget *
byk_settings_control (BykSettingsPage *self, const ByakaronSettingsField *f)
{
    gint value = 0;
    if (self->engines->composer != NULL)
        byakaron_setting_get (self->engines->composer, f->key, &value);

    GtkWidget *control;
    switch (f->control) {
    case BYAKARON_CONTROL_CHOICE:
        control = gtk_combo_box_text_new ();
        for (gsize i = 0; i < f->option_count; i++)
            gtk_combo_box_text_append_text (GTK_COMBO_BOX_TEXT (control), f->option_labels[i]);
        gtk_combo_box_set_active (GTK_COMBO_BOX (control), value);
        g_signal_connect (control, "changed", G_CALLBACK (on_choice_changed), self);
        break;
    case BYAKARON_CONTROL_NUMBER:
        control = gtk_spin_button_new_with_range (f->min, f->max, 1);
        gtk_spin_button_set_value (GTK_SPIN_BUTTON (control), value);
        g_signal_connect (control, "value-changed", G_CALLBACK (on_number_changed), self);
        break;
    default:
        control = gtk_switch_new ();
        gtk_switch_set_active (GTK_SWITCH (control), value != 0);
        g_signal_connect (control, "notify::active", G_CALLBACK (on_switch_changed), self);
        break;
    }
    g_object_set_data (G_OBJECT (control), "byk-key", (gpointer) f->key);
    return control;
}

/*
 * One manifest section (Settings.zig) as a group, or NULL when no field of it
 * applies to Linux. Each tab shows one section, as on macOS and Windows.
 */
static GtkWidget *
byk_settings_build_section (BykSettingsPage *self, const gchar *section_id)
{
    const gchar *lang = byk_settings_lang ();
    const gsize n_sections = byakaron_settings_section_count ();
    const gsize n_fields = byakaron_settings_field_count ();

    for (gsize s = 0; s < n_sections; s++) {
        ByakaronSettingsSection section;
        if (byakaron_settings_section_info (s, lang, &section) != 0 ||
            g_strcmp0 (section.id, section_id) != 0)
            continue;

        GtkWidget *list = NULL;
        GtkWidget *group = NULL;
        for (gsize i = 0; i < n_fields; i++) {
            ByakaronSettingsField f;
            if (byakaron_settings_field_info (i, lang, &f) != 0 || f.section != s ||
                (f.platforms & BYAKARON_PLATFORM_LINUX) == 0)
                continue;
            if (group == NULL)
                group = byk_framed_list (section.title, section.hint, &list);
            byk_settings_add_row (list, f.title, f.hint, byk_settings_control (self, &f));
        }
        if (group == NULL)
            return NULL;
        /* Under the update settings: Check Now (updates.c, through the window). */
        if (g_strcmp0 (section.id, "updates") == 0) {
            GtkWidget *now = gtk_button_new_with_label ("Check Now");
            gtk_actionable_set_action_name (GTK_ACTIONABLE (now), "win.check-updates");
            gchar *version = g_strdup_printf ("This is Byakaron %s.", BYK_APP_VERSION);
            byk_settings_add_row (list, "Check now", version, now);
            g_free (version);
        }
        if (self->engines->composer == NULL)
            gtk_widget_set_sensitive (list, FALSE);
        return group;
    }
    return NULL;
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
byk_settings_page_new (BykEngines *engines, const gchar *section_id)
{
    BykSettingsPage *self = g_object_new (BYK_TYPE_SETTINGS_PAGE, NULL);
    self->engines = engines;

    GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_halign (column, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request (column, 420, -1);
    gtk_widget_set_margin_bottom (column, 24);

    GtkWidget *group = byk_settings_build_section (self, section_id);
    if (group != NULL)
        byk_box_add (column, group);

    /* The Qt click fix is about typing, so it sits under the Typing settings,
     * as the one Linux-only group. */
    if (g_strcmp0 (section_id, "typing") == 0) {
        self->prefs = byk_prefs_try_open ();
        if (self->prefs != NULL)
            byk_box_add (column, byk_settings_build_compat (self));
    }

    GtkWidget *scroller = byk_scroller (column, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand (scroller, TRUE);
    byk_box_add_expand (GTK_WIDGET (self), scroller);
    return GTK_WIDGET (self);
}
