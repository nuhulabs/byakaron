#include "setup.h"

#include "prefs.h"
#include "uiutil.h"

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
    GtkBox parent_instance;

    GtkWidget *status_title;
    GtkWidget *status_subtitle;
    GtkWidget *status_icon;
    GtkWidget *install_hint; /* only shown when nothing is installed */
    GtkWidget *toast;

    GSettings *prefs; /* NULL when the schema is not installed */
};

G_DEFINE_TYPE (BykSetupPage, byk_setup_page, GTK_TYPE_BOX)

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
    gchar *found = g_find_program_in_path ("gnome-control-center");
    if (found == NULL) {
        byk_toast_show (GTK_LABEL (self->toast),
                        "GNOME Settings not found — open your desktop's "
                        "keyboard settings and add Byakaron there");
        return;
    }
    g_free (found);

    GError *error = NULL;
    const gchar *argv[] = { "gnome-control-center", "keyboard", NULL };

    if (!g_spawn_async (NULL, (gchar **) argv, NULL,
                        G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL |
                            G_SPAWN_STDERR_TO_DEV_NULL,
                        NULL, NULL, NULL, &error)) {
        gchar *message = g_strdup_printf ("Could not open Settings: %s", error->message);
        byk_toast_show (GTK_LABEL (self->toast), message);
        g_free (message);
        g_clear_error (&error);
    }
}

static void
on_copy_install_clicked (GtkButton *button, gpointer user_data)
{
    BykSetupPage *self = BYK_SETUP_PAGE (user_data);
    (void) button;

    byk_clipboard_set (GTK_WIDGET (self),
                       "sudo bash platforms/linux/scripts/install.sh");
    byk_toast_show (GTK_LABEL (self->toast), "Install command copied");
}

/* ── rows ────────────────────────────────────────────────────────────────── */

static GtkWidget *
byk_setup_row (GtkWidget *prefix, const gchar *title, const gchar *subtitle, GtkWidget *suffix)
{
    GtkWidget *labels = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
    GtkWidget *title_w = gtk_label_new (title);
    gtk_label_set_xalign (GTK_LABEL (title_w), 0.0);
    gtk_label_set_line_wrap (GTK_LABEL (title_w), TRUE);
    byk_box_add (labels, title_w);

    GtkWidget *sub_w = NULL;
    if (subtitle != NULL) {
        sub_w = gtk_label_new (subtitle);
        byk_css_add (sub_w, "dim-label");
        gtk_label_set_xalign (GTK_LABEL (sub_w), 0.0);
        gtk_label_set_line_wrap (GTK_LABEL (sub_w), TRUE);
        byk_box_add (labels, sub_w);
    }

    GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_top (row, 8);
    gtk_widget_set_margin_bottom (row, 8);
    gtk_widget_set_margin_start (row, 12);
    gtk_widget_set_margin_end (row, 12);
    if (prefix != NULL) {
        gtk_widget_set_valign (prefix, GTK_ALIGN_CENTER);
        byk_box_add (row, prefix);
    }
    gtk_widget_set_hexpand (labels, TRUE);
    byk_box_add_expand (row, labels);
    if (suffix != NULL) {
        gtk_widget_set_valign (suffix, GTK_ALIGN_CENTER);
        byk_box_add (row, suffix);
    }

    g_object_set_data (G_OBJECT (row), "byk-title", title_w);
    g_object_set_data (G_OBJECT (row), "byk-subtitle", sub_w);
    return row;
}

static GtkWidget *
byk_setup_step_row (guint number, const gchar *text, const gchar *note)
{
    gchar *label = g_strdup_printf ("%u", number);
    GtkWidget *badge = gtk_label_new (label);
    g_free (label);

    byk_css_add (badge, "byk-step");
    gtk_widget_set_valign (badge, GTK_ALIGN_CENTER);
    gtk_widget_set_halign (badge, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request (badge, 24, 24);

    return byk_setup_row (badge, text, note, NULL);
}

static GtkWidget *
byk_setup_tip_row (const gchar *key, const gchar *meaning)
{
    GtkWidget *value = gtk_label_new (meaning);
    byk_css_add (value, "dim-label");
    gtk_label_set_line_wrap (GTK_LABEL (value), TRUE);
    gtk_label_set_max_width_chars (GTK_LABEL (value), 40);
    gtk_label_set_xalign (GTK_LABEL (value), 1.0);
    return byk_setup_row (NULL, key, NULL, value);
}

static GtkWidget *
byk_setup_link_row (const gchar *title, const gchar *uri)
{
    GtkWidget *link = gtk_link_button_new_with_label (uri, "Open");
    return byk_setup_row (NULL, title, NULL, link);
}

static GtkWidget *
byk_setup_switch_row (const gchar *title, const gchar *subtitle, GtkWidget **out_switch)
{
    GtkWidget *sw = gtk_switch_new ();
    *out_switch = sw;
    return byk_setup_row (NULL, title, subtitle, sw);
}

static GtkWidget *
byk_framed_list (const gchar *title, const gchar *description, GtkWidget **out_box)
{
    GtkWidget *outer = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start (outer, 18);
    gtk_widget_set_margin_end (outer, 18);
    gtk_widget_set_margin_top (outer, 12);

    if (title != NULL) {
        GtkWidget *label = gtk_label_new (title);
        byk_css_add (label, "heading");
        gtk_widget_set_halign (label, GTK_ALIGN_START);
        byk_box_add (outer, label);
    }
    if (description != NULL) {
        GtkWidget *label = gtk_label_new (description);
        byk_css_add (label, "dim-label");
        gtk_label_set_line_wrap (GTK_LABEL (label), TRUE);
        gtk_label_set_xalign (GTK_LABEL (label), 0.0);
        byk_box_add (outer, label);
    }

    GtkWidget *list = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *frame = gtk_frame_new (NULL);
    gtk_container_add (GTK_CONTAINER (frame), list);
    byk_box_add (outer, frame);
    *out_box = list;
    return outer;
}

/* ── construction ────────────────────────────────────────────────────────── */

static GtkWidget *
byk_setup_page_build_status (BykSetupPage *self)
{
    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list (NULL, NULL, &list);

    self->status_icon = gtk_image_new_from_icon_name ("dialog-information-symbolic",
                                                      GTK_ICON_SIZE_BUTTON);
    gtk_image_set_pixel_size (GTK_IMAGE (self->status_icon), 24);

    GtkWidget *recheck = gtk_button_new_with_label ("Re-check");
    g_signal_connect (recheck, "clicked", G_CALLBACK (on_recheck_clicked), self);

    GtkWidget *status = byk_setup_row (self->status_icon, "", "", recheck);
    self->status_title = g_object_get_data (G_OBJECT (status), "byk-title");
    self->status_subtitle = g_object_get_data (G_OBJECT (status), "byk-subtitle");
    byk_box_add (list, status);

    GtkWidget *copy = gtk_button_new_with_label ("Copy install command");
    g_signal_connect (copy, "clicked", G_CALLBACK (on_copy_install_clicked), self);

    self->install_hint = byk_setup_row (
        NULL,
        "Install the input method",
        "Run the install script from a checkout, or install the .deb",
        copy);
    byk_hide_until_shown (self->install_hint);
    byk_box_add (list, self->install_hint);

    return group;
}

static GtkWidget *
byk_setup_page_build_steps (BykSetupPage *self)
{
    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list ("Set Up", NULL, &list);

    byk_box_add (list, byk_setup_step_row (
        1, "Open Settings \u2192 Keyboard \u2192 Input Sources",
        "Byakaron installs as a system input source"));
    byk_box_add (list, gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
    byk_box_add (list, byk_setup_step_row (
        2, "Click  +  \u2192 choose Bangla \u2192 select Byakaron \u2192 Add",
        NULL));
    byk_box_add (list, gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
    byk_box_add (list, byk_setup_step_row (
        3, "Switch to it with Super+Space", NULL));

    GtkWidget *open = gtk_button_new_with_label ("Open Input Sources");
    gtk_widget_set_halign (open, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top (open, 12);
    gtk_widget_set_margin_bottom (open, 8);
    byk_css_add (open, "suggested-action");
    g_signal_connect (open, "clicked", G_CALLBACK (on_open_settings_clicked), self);
    byk_box_add (list, open);

    return group;
}

static GtkWidget *
byk_setup_page_build_typing (void)
{
    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list ("How to Type", NULL, &list);

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
        { ".", "dari (ami. \u2192 আমি।)" },
        { "Page Up / Page Down", "moves through pages of candidates" },
        { "Backspace", "deletes the last character" },
        { "Escape", "cancels the current word and its candidates" },
    };

    for (gsize i = 0; i < G_N_ELEMENTS (TIPS); i++) {
        if (i > 0)
            byk_box_add (list, gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
        byk_box_add (list, byk_setup_tip_row (TIPS[i].key, TIPS[i].meaning));
    }

    return group;
}

static GtkWidget *
byk_setup_page_build_prefs (BykSetupPage *self)
{
    self->prefs = byk_prefs_try_open ();
    if (self->prefs == NULL)
        return NULL;

    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list (
        "Preferences",
        "These apply to the input method and to Write as soon as you change them.",
        &list);

    GtkWidget *suggest_sw = NULL;
    GtkWidget *suggest = byk_setup_switch_row (
        "Suggest words",
        "Dictionary completions while typing. 1\u20139 pick one. Off still transliterates.",
        &suggest_sw);
    g_settings_bind (self->prefs, BYK_PREFS_PHONETIC_ONLY, suggest_sw, "active",
                     G_SETTINGS_BIND_DEFAULT | G_SETTINGS_BIND_INVERT_BOOLEAN);
    byk_box_add (list, suggest);
    byk_box_add (list, gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));

    GtkWidget *horiz_sw = NULL;
    GtkWidget *horiz = byk_setup_switch_row (
        "Horizontal candidate list",
        "The input method panel. Off for a vertical list.",
        &horiz_sw);
    g_settings_bind (self->prefs, BYK_PREFS_CANDIDATES_HORIZONTAL, horiz_sw, "active",
                     G_SETTINGS_BIND_DEFAULT);
    byk_box_add (list, horiz);

    return group;
}

static GtkWidget *
byk_setup_page_build_about (void)
{
    GtkWidget *list = NULL;
    GtkWidget *group = byk_framed_list ("About", "Developed by Nurul Huda (Apon)", &list);

    GtkWidget *version = gtk_label_new (BYK_APP_VERSION);
    byk_css_add (version, "dim-label");
    byk_box_add (list, byk_setup_row (NULL, "Version", NULL, version));
    byk_box_add (list, gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
    byk_box_add (list, byk_setup_link_row ("Source code", BYK_URL_GITHUB));
    byk_box_add (list, gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
    byk_box_add (list, byk_setup_link_row ("Website", BYK_URL_WEBSITE));

    return group;
}

static void
byk_setup_page_init (BykSetupPage *self)
{
    gtk_orientable_set_orientation (GTK_ORIENTABLE (self), GTK_ORIENTATION_VERTICAL);
}

static void
byk_setup_page_dispose (GObject *object)
{
    BykSetupPage *self = BYK_SETUP_PAGE (object);
    g_clear_object (&self->prefs);
    G_OBJECT_CLASS (byk_setup_page_parent_class)->dispose (object);
}

static void
byk_setup_page_class_init (BykSetupPageClass *klass)
{
    G_OBJECT_CLASS (klass)->dispose = byk_setup_page_dispose;
}

GtkWidget *
byk_setup_page_new (void)
{
    BykSetupPage *self = g_object_new (BYK_TYPE_SETUP_PAGE, NULL);

    GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_halign (column, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request (column, 360, -1);
    gtk_widget_set_margin_bottom (column, 24);
    byk_box_add (column, byk_setup_page_build_status (self));
    byk_box_add (column, byk_setup_page_build_steps (self));
    byk_box_add (column, byk_setup_page_build_typing ());
    {
        GtkWidget *prefs = byk_setup_page_build_prefs (self);
        if (prefs != NULL)
            byk_box_add (column, prefs);
    }
    byk_box_add (column, byk_setup_page_build_about ());

    self->toast = gtk_label_new ("");
    byk_css_add (self->toast, "byk-toast");
    byk_css_add (self->toast, "dim-label");
    byk_hide_until_shown (self->toast);
    byk_box_add (column, self->toast);

    GtkWidget *scroller = byk_scroller (column, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    byk_box_add_expand (GTK_WIDGET (self), scroller);

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

    gtk_image_set_from_icon_name (GTK_IMAGE (self->status_icon), icon, GTK_ICON_SIZE_BUTTON);
    gtk_label_set_text (GTK_LABEL (self->status_title), title);
    gtk_label_set_text (GTK_LABEL (self->status_subtitle), subtitle);

    byk_css_remove (self->status_icon, "error");
    byk_css_remove (self->status_icon, "warning");
    byk_css_remove (self->status_icon, "success");
    byk_css_add (self->status_icon, css);

    gtk_widget_set_visible (self->install_hint,
                            byk_keyboard_state () == BYK_KEYBOARD_MISSING);
}
