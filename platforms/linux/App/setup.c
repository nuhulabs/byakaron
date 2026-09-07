#include "setup.h"

/* The only directory ibus-daemon scans for components; scripts/install.sh
 * writes here and nowhere else, so its presence is the installed check. */
#define BYK_COMPONENT_XML "/usr/share/ibus/component/byakaron.xml"
#define BYK_ENGINE_NAME   "byakaron"

#define BYK_INPUT_SOURCES_SCHEMA "org.gnome.desktop.input-sources"

typedef enum {
    BYK_KEYBOARD_MISSING, /* not installed on the system */
    BYK_KEYBOARD_READY,   /* installed, but not in the user's input sources */
    BYK_KEYBOARD_ADDED,   /* installed and added */
} BykKeyboardState;

struct _BykSetupPage {
    AdwBin parent_instance;

    AdwActionRow *status_row;
    GtkWidget *status_icon;
    GtkWidget *install_hint; /* only shown when nothing is installed */

    AdwToastOverlay *toasts;
};

G_DEFINE_FINAL_TYPE (BykSetupPage, byk_setup_page, ADW_TYPE_BIN)

/* ── detection ───────────────────────────────────────────────────────────── */

/*
 * Whether "byakaron" is in the user's input sources.
 *
 * Read from GSettings rather than by running `ibus engine`, because the list
 * of *added* sources is desktop configuration, not daemon state. The schema is
 * looked up before use: g_settings_new aborts the process on an unknown
 * schema, which is a real possibility outside GNOME.
 */
static gboolean
byk_input_source_added (void)
{
    GSettingsSchemaSource *source = g_settings_schema_source_get_default ();
    if (source == NULL)
        return FALSE;

    GSettingsSchema *schema =
        g_settings_schema_source_lookup (source, BYK_INPUT_SOURCES_SCHEMA, TRUE);
    if (schema == NULL)
        return FALSE;
    g_settings_schema_unref (schema);

    GSettings *settings = g_settings_new (BYK_INPUT_SOURCES_SCHEMA);
    GVariant *sources = g_settings_get_value (settings, "sources");
    gboolean found = FALSE;

    /* a(ss) of (backend, id), e.g. ('xkb', 'us') or ('ibus', 'byakaron'). */
    GVariantIter iter;
    const gchar *backend = NULL;
    const gchar *id = NULL;

    g_variant_iter_init (&iter, sources);
    while (g_variant_iter_next (&iter, "(&s&s)", &backend, &id)) {
        if (g_strcmp0 (backend, "ibus") == 0 && g_strcmp0 (id, BYK_ENGINE_NAME) == 0) {
            found = TRUE;
            break;
        }
    }

    g_variant_unref (sources);
    g_object_unref (settings);
    return found;
}

static BykKeyboardState
byk_keyboard_state (void)
{
    if (!g_file_test (BYK_COMPONENT_XML, G_FILE_TEST_IS_REGULAR))
        return BYK_KEYBOARD_MISSING;

    return byk_input_source_added () ? BYK_KEYBOARD_ADDED : BYK_KEYBOARD_READY;
}

/* ── actions ─────────────────────────────────────────────────────────────── */

static void
on_recheck_clicked (GtkButton *button, gpointer user_data)
{
    (void) button;
    byk_setup_page_refresh (BYK_SETUP_PAGE (user_data));
}

static void
on_open_settings_clicked (GtkButton *button, gpointer user_data)
{
    BykSetupPage *self = BYK_SETUP_PAGE (user_data);
    (void) button;

    /* GNOME's keyboard panel is where input sources live. There is no portal
     * or D-Bus interface for "open this settings panel", so this is a plain
     * spawn — and a missing binary is a normal outcome on other desktops. */
    if (g_find_program_in_path ("gnome-control-center") == NULL) {
        adw_toast_overlay_add_toast (
            self->toasts,
            adw_toast_new ("GNOME Settings not found — open your desktop's "
                           "keyboard settings and add Byakaron there"));
        return;
    }

    GError *error = NULL;
    const gchar *argv[] = { "gnome-control-center", "keyboard", NULL };

    if (!g_spawn_async (NULL, (gchar **) argv, NULL,
                        G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL |
                            G_SPAWN_STDERR_TO_DEV_NULL,
                        NULL, NULL, NULL, &error)) {
        gchar *message = g_strdup_printf ("Could not open Settings: %s", error->message);
        adw_toast_overlay_add_toast (self->toasts, adw_toast_new (message));
        g_free (message);
        g_clear_error (&error);
    }
}

static void
on_copy_install_clicked (GtkButton *button, gpointer user_data)
{
    BykSetupPage *self = BYK_SETUP_PAGE (user_data);
    (void) button;

    gdk_clipboard_set_text (gtk_widget_get_clipboard (GTK_WIDGET (self)),
                            "sudo bash platforms/linux/scripts/install.sh");
    adw_toast_overlay_add_toast (self->toasts, adw_toast_new ("Install command copied"));
}

/* ── rows ────────────────────────────────────────────────────────────────── */

static GtkWidget *
byk_setup_step_row (guint number, const gchar *text, const gchar *note)
{
    gchar *label = g_strdup_printf ("%u", number);
    GtkWidget *badge = gtk_label_new (label);
    g_free (label);

    gtk_widget_add_css_class (badge, "byk-step");
    gtk_widget_set_valign (badge, GTK_ALIGN_CENTER);

    AdwActionRow *row = ADW_ACTION_ROW (adw_action_row_new ());
    adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), text);
    adw_preferences_row_set_use_markup (ADW_PREFERENCES_ROW (row), FALSE);
    adw_action_row_add_prefix (row, badge);
    if (note != NULL)
        adw_action_row_set_subtitle (row, note);

    return GTK_WIDGET (row);
}

static GtkWidget *
byk_setup_tip_row (const gchar *key, const gchar *meaning)
{
    AdwActionRow *row = ADW_ACTION_ROW (adw_action_row_new ());
    GtkWidget *value = gtk_label_new (meaning);

    adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), key);
    adw_preferences_row_set_use_markup (ADW_PREFERENCES_ROW (row), FALSE);
    gtk_widget_add_css_class (value, "dim-label");
    gtk_label_set_wrap (GTK_LABEL (value), TRUE);
    gtk_label_set_max_width_chars (GTK_LABEL (value), 40);
    gtk_label_set_xalign (GTK_LABEL (value), 1.0);
    adw_action_row_add_suffix (row, value);

    return GTK_WIDGET (row);
}

static GtkWidget *
byk_setup_link_row (const gchar *title, const gchar *uri)
{
    AdwActionRow *row = ADW_ACTION_ROW (adw_action_row_new ());
    GtkWidget *link = gtk_link_button_new_with_label (uri, "Open");

    adw_preferences_row_set_title (ADW_PREFERENCES_ROW (row), title);
    adw_action_row_add_suffix (row, link);
    adw_action_row_set_activatable_widget (row, link);

    return GTK_WIDGET (row);
}

/* ── construction ────────────────────────────────────────────────────────── */

static GtkWidget *
byk_setup_page_build_status (BykSetupPage *self)
{
    GtkWidget *group = adw_preferences_group_new ();

    self->status_icon = gtk_image_new ();
    gtk_image_set_pixel_size (GTK_IMAGE (self->status_icon), 24);

    GtkWidget *recheck = gtk_button_new_with_label ("Re-check");
    gtk_widget_set_valign (recheck, GTK_ALIGN_CENTER);
    g_signal_connect (recheck, "clicked", G_CALLBACK (on_recheck_clicked), self);

    self->status_row = ADW_ACTION_ROW (adw_action_row_new ());
    adw_action_row_add_prefix (self->status_row, self->status_icon);
    adw_action_row_add_suffix (self->status_row, recheck);

    adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), GTK_WIDGET (self->status_row));

    /* Only meaningful before the engine is installed, so it is hidden the rest
     * of the time rather than sitting there as permanent noise. */
    GtkWidget *copy = gtk_button_new_with_label ("Copy install command");
    gtk_widget_set_valign (copy, GTK_ALIGN_CENTER);
    g_signal_connect (copy, "clicked", G_CALLBACK (on_copy_install_clicked), self);

    self->install_hint = adw_action_row_new ();
    adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->install_hint),
                                   "Install the input method");
    adw_action_row_set_subtitle (ADW_ACTION_ROW (self->install_hint),
                                 "Run the install script from a checkout, or install the .deb");
    adw_action_row_add_suffix (ADW_ACTION_ROW (self->install_hint), copy);
    adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), self->install_hint);

    return group;
}

static GtkWidget *
byk_setup_page_build_steps (BykSetupPage *self)
{
    GtkWidget *group = adw_preferences_group_new ();
    adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (group), "Set Up");

    adw_preferences_group_add (
        ADW_PREFERENCES_GROUP (group),
        byk_setup_step_row (1, "Open Settings \u2192 Keyboard \u2192 Input Sources",
                            "Byakaron installs as a system input source"));
    adw_preferences_group_add (
        ADW_PREFERENCES_GROUP (group),
        byk_setup_step_row (2, "Click  +  \u2192 choose Bangla \u2192 select Byakaron \u2192 Add",
                            NULL));
    adw_preferences_group_add (
        ADW_PREFERENCES_GROUP (group),
        byk_setup_step_row (3, "Switch to it with Super+Space", NULL));

    GtkWidget *open = gtk_button_new_with_label ("Open Input Sources");
    gtk_widget_set_halign (open, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top (open, 12);
    gtk_widget_add_css_class (open, "suggested-action");
    gtk_widget_add_css_class (open, "pill");
    g_signal_connect (open, "clicked", G_CALLBACK (on_open_settings_clicked), self);
    adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), open);

    return group;
}

static GtkWidget *
byk_setup_page_build_typing (void)
{
    GtkWidget *group = adw_preferences_group_new ();
    adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (group), "How to Type");

    /*
     * Deliberately not a copy of the macOS cheat-sheet. This engine commits
     * what was typed rather than the top suggestion, has no arrow-key
     * navigation, and pages with Page Up / Page Down — describing macOS's
     * behaviour here would be describing a different keyboard.
     */
    static const struct {
        const gchar *key;
        const gchar *meaning;
    } TIPS[] = {
        { "Type phonetically", "ami \u2192 আমি,  bangla \u2192 বাংলা" },
        { "Space", "commits the word you typed" },
        { "1\u20139", "picks a candidate while the list is showing" },
        { "0\u20139", "Bangla numerals otherwise (2024 \u2192 ২০২৪)" },
        { "Page Up / Page Down", "moves through pages of candidates" },
        { "Backspace", "deletes the last character" },
        { "Escape", "cancels the current word and its candidates" },
    };

    for (gsize i = 0; i < G_N_ELEMENTS (TIPS); i++)
        adw_preferences_group_add (ADW_PREFERENCES_GROUP (group),
                                   byk_setup_tip_row (TIPS[i].key, TIPS[i].meaning));

    return group;
}

static GtkWidget *
byk_setup_page_build_about (void)
{
    GtkWidget *group = adw_preferences_group_new ();
    adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (group), "About");

    AdwActionRow *version = ADW_ACTION_ROW (adw_action_row_new ());
    GtkWidget *value = gtk_label_new (BYK_APP_VERSION);
    adw_preferences_row_set_title (ADW_PREFERENCES_ROW (version), "Version");
    gtk_widget_add_css_class (value, "dim-label");
    adw_action_row_add_suffix (version, value);
    adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), GTK_WIDGET (version));

    adw_preferences_group_add (ADW_PREFERENCES_GROUP (group),
                               byk_setup_link_row ("Source code", BYK_URL_GITHUB));
    adw_preferences_group_add (ADW_PREFERENCES_GROUP (group),
                               byk_setup_link_row ("Website", BYK_URL_WEBSITE));

    adw_preferences_group_set_description (ADW_PREFERENCES_GROUP (group),
                                           "Developed by Nurul Huda (Apon)");

    return group;
}

static void
byk_setup_page_init (BykSetupPage *self)
{
    (void) self;
}

static void
byk_setup_page_class_init (BykSetupPageClass *klass)
{
    (void) klass;
}

GtkWidget *
byk_setup_page_new (void)
{
    BykSetupPage *self = g_object_new (BYK_TYPE_SETUP_PAGE, NULL);

    GtkWidget *page = adw_preferences_page_new ();
    adw_preferences_page_add (ADW_PREFERENCES_PAGE (page),
                              ADW_PREFERENCES_GROUP (byk_setup_page_build_status (self)));
    adw_preferences_page_add (ADW_PREFERENCES_PAGE (page),
                              ADW_PREFERENCES_GROUP (byk_setup_page_build_steps (self)));
    adw_preferences_page_add (ADW_PREFERENCES_PAGE (page),
                              ADW_PREFERENCES_GROUP (byk_setup_page_build_typing ()));
    adw_preferences_page_add (ADW_PREFERENCES_PAGE (page),
                              ADW_PREFERENCES_GROUP (byk_setup_page_build_about ()));

    self->toasts = ADW_TOAST_OVERLAY (adw_toast_overlay_new ());
    adw_toast_overlay_set_child (self->toasts, page);
    adw_bin_set_child (ADW_BIN (self), GTK_WIDGET (self->toasts));

    byk_setup_page_refresh (self);
    return GTK_WIDGET (self);
}

void
byk_setup_page_refresh (BykSetupPage *self)
{
    g_return_if_fail (BYK_IS_SETUP_PAGE (self));

    const gchar *icon = NULL;
    const gchar *title = NULL;
    const gchar *subtitle = NULL;
    const gchar *css = NULL;

    switch (byk_keyboard_state ()) {
    case BYK_KEYBOARD_MISSING:
        icon = "dialog-warning-symbolic";
        title = "Keyboard isn\u2019t installed yet";
        subtitle = "Nothing is registered with IBus on this system.";
        css = "error";
        break;
    case BYK_KEYBOARD_READY:
        icon = "dialog-information-symbolic";
        title = "Keyboard isn\u2019t added yet";
        subtitle = "It is installed. Add it under Input Sources to start typing.";
        css = "warning";
        break;
    case BYK_KEYBOARD_ADDED:
        icon = "emblem-ok-symbolic";
        title = "Keyboard is added";
        subtitle = "Press Super+Space to switch to Byakaron.";
        css = "success";
        break;
    }

    gtk_image_set_from_icon_name (GTK_IMAGE (self->status_icon), icon);
    adw_preferences_row_set_title (ADW_PREFERENCES_ROW (self->status_row), title);
    adw_action_row_set_subtitle (self->status_row, subtitle);

    gtk_widget_remove_css_class (self->status_icon, "error");
    gtk_widget_remove_css_class (self->status_icon, "warning");
    gtk_widget_remove_css_class (self->status_icon, "success");
    gtk_widget_add_css_class (self->status_icon, css);

    gtk_widget_set_visible (self->install_hint,
                            byk_keyboard_state () == BYK_KEYBOARD_MISSING);
}
