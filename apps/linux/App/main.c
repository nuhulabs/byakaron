/*
 * byakaron — the GTK3 companion app to the input method.
 *
 * GTK3 3.24 is on Ubuntu 20.04, 22.04, and 24.04. GTK4 and libadwaita 1.4 are
 * not, so this app stays on GTK3 rather than shipping a UI that only the
 * newest release can open.
 *
 * The window is the spelling editor, laid out like the macOS and Windows apps
 * (issue list, editor, the controls in the header bar). Setup, the settings,
 * the personal dictionary and the Avro key map are in Preferences, reached the
 * GNOME way: the primary menu or Ctrl+comma; About is in the same menu.
 * `byakaron --page=setup` (IBus Preferences) opens Setup.
 *
 * It is a separate process from byakaron-ibus and shares nothing with it at
 * runtime but the Core/ glue and the Zig engine underneath — the input method
 * keeps working whether or not this is installed or running.
 */
#include <stdlib.h>

#include "app.h"
#include "prefs.h"
#include "window.h"

/*
 * Type sizes and the step badge, plus a few Adwaita-style names that GTK3's
 * stylesheet does not define, and one accent blue for the whole app.
 *
 * Yaru writes its orange into each widget's rule, so redefining the theme's
 * selected colour would change nothing: the widgets that show the accent are
 * named here instead. This provider outranks the theme whatever the selector,
 * so a plain `switch:checked` beats Yaru's longer ones. Light and dark still
 * come from the theme.
 */
static const char BYK_CSS[] =
    "@define-color byk_accent #0a84ff;\n"
    "@define-color byk_accent_dark #0870d8;\n"
    "* { -gtk-secondary-caret-color: @byk_accent; }\n"
    "*:focus { outline-color: alpha(@byk_accent, 0.7); }\n"
    "selection { background-color: @byk_accent; color: #ffffff; }\n"
    "switch:checked { background: @byk_accent; border-color: @byk_accent_dark; }\n"
    "switch:checked > slider { border-color: @byk_accent_dark; }\n"
    "check:checked, radio:checked, check:indeterminate, radio:indeterminate {\n"
    "  background-image: image(@byk_accent); border-color: @byk_accent;\n"
    "}\n"
    "row:selected, row.activatable:selected, .view:selected, .view text:selected,\n"
    "textview text:selected, treeview.view:selected, iconview:selected,\n"
    "flowboxchild:selected, menu menuitem:hover, .context-menu menuitem:hover {\n"
    "  background-color: @byk_accent; color: #ffffff;\n"
    "}\n"
    "entry:focus, spinbutton:focus {\n"
    "  border-color: alpha(@byk_accent, 0.7);\n"
    "  box-shadow: inset 0 0 0 1px alpha(@byk_accent, 0.7);\n"
    "}\n"
    "button:link > label, *:link { color: @byk_accent_dark; }\n"
    "progressbar progress, scale highlight {\n"
    "  background-color: @byk_accent; border-color: @byk_accent;\n"
    "}\n"
    "scrollbar slider:hover:active { background-color: @byk_accent; }\n"
    ".rubberband { background-color: alpha(@byk_accent, 0.2); border: 1px solid @byk_accent; }\n"
    ".heading { font-weight: bold; }\n"
    ".caption { font-size: smaller; }\n"
    ".monospace { font-family: monospace; }\n"
    ".success { color: #26a269; }\n"
    ".warning { color: #e5a50a; }\n"
    ".error { color: #c01c28; }\n"
    ".card { border: 1px solid alpha(@theme_fg_color, 0.15); border-radius: 8px; }\n"
    ".byk-bangla { font-size: 1.25rem; }\n"
    ".byk-layout-glyph { font-size: 1.4rem; }\n"
    /* Accent pulled toward the text colour: readable on light and dark. */
    ".byk-layout-keys { color: mix(@byk_accent, @theme_fg_color, 0.3); font-weight: 600; }\n"
    ".byk-toast { padding: 8px 12px; }\n"
    ".byk-issue-word { font-weight: 600; }\n"
    /*
     * The candidate pills. Compact on purpose: a word is the only thing in
     * here, so the panel is barely taller than the word itself. The rest
     * follows light and dark. Resources/gnome-shell/panel.css is this same
     * look for the popup GNOME Shell draws, and macOS and Windows draw it too
     * (apps/macos/Core/Composer/CandidatePanel.swift,
     * apps/windows/Keyboard/CandidateWindow.cpp): change them together.
     */
    ".byk-pill {\n"
    "  background-color: mix(@theme_base_color, @theme_fg_color, 0.04);\n"
    "  border: 1px solid alpha(@theme_fg_color, 0.12);\n"
    "  border-radius: 999px;\n"
    "  padding: 2px;\n"
    "}\n"
    ".byk-pill-floating {\n"
    "  margin: 4px;\n"
    "  box-shadow: 0 1px 4px alpha(black, 0.28);\n"
    "}\n"
    ".byk-pill-tall { border-radius: 12px; }\n"
    "button.byk-pill-item, button.byk-pill-chevron {\n"
    "  min-width: 0; min-height: 0;\n"
    "  border: none; outline-color: transparent;\n"
    "  background: none; box-shadow: none; text-shadow: none;\n"
    "  color: @theme_fg_color;\n"
    "}\n"
    "button.byk-pill-item { padding: 0 9px; border-radius: 999px; font-size: 1.2rem; }\n"
    "button.byk-pill-item:hover { background-color: alpha(@theme_fg_color, 0.09); }\n"
    "button.byk-pill-item.byk-pill-selected { background-color: @byk_accent; color: #ffffff; }\n"
    ".byk-pill-number { font-size: 0.72rem; opacity: 0.6; }\n"
    ".byk-pill-selected .byk-pill-number { opacity: 0.9; }\n"
    "button.byk-pill-chevron { padding: 0 3px; border-radius: 6px; opacity: 0.7; }\n"
    "button.byk-pill-chevron:hover { opacity: 1; background-color: alpha(@theme_fg_color, 0.09); }\n"
    ".byk-step {\n"
    "  min-width: 24px; min-height: 24px;\n"
    "  border-radius: 999px;\n"
    "  background-color: @byk_accent;\n"
    "  color: #ffffff;\n"
    "  font-weight: bold;\n"
    "}\n";

static const char *const AUTHORS[] = { "Nuhu Labs", NULL };

static const GOptionEntry extra_options[] = {
    { "version", 'V', 0, G_OPTION_ARG_NONE, NULL, "Print the version and exit", NULL },
    { "page", 'p', 0, G_OPTION_ARG_STRING, NULL,
      "Open this page: spelling, setup, typing, candidates, dictionary, layout, or updates", "PAGE" },
    { NULL }
};

/* Return 0 to exit successfully (after --version); -1 to continue startup. */
static gint
on_handle_local_options (GApplication *app, GVariantDict *options, gpointer user_data)
{
    (void) app;
    (void) user_data;
    if (g_variant_dict_contains (options, "version")) {
        g_print ("byakaron %s\n", BYK_APP_VERSION);
        return 0;
    }
    return -1;
}

static void
on_about_activate (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
    GtkApplication *app = GTK_APPLICATION (user_data);
    (void) action;
    (void) parameter;

    gtk_show_about_dialog (gtk_application_get_active_window (app),
                           "program-name", "Byakaron",
                           "logo-icon-name", "byakaron",
                           "version", BYK_APP_VERSION,
                           "authors", AUTHORS,
                           "copyright", "Nuhu Labs",
                           "license-type", GTK_LICENSE_MIT_X11,
                           "website", BYK_URL_WEBSITE,
                           "comments",
                           "Bangla phonetic input method and spell checker, "
                           "over a shared Zig engine.",
                           NULL);
}

static void
on_quit_activate (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
    (void) action;
    (void) parameter;
    g_application_quit (G_APPLICATION (user_data));
}

static void
byk_add_app_action (GApplication *app,
                    const gchar *name,
                    GCallback activate)
{
    GSimpleAction *action = g_simple_action_new (name, NULL);
    g_signal_connect (action, "activate", activate, app);
    g_action_map_add_action (G_ACTION_MAP (app), G_ACTION (action));
    g_object_unref (action);
}

static void
on_startup (GApplication *app, gpointer user_data)
{
    (void) user_data;

    GtkCssProvider *provider = gtk_css_provider_new ();
    gtk_css_provider_load_from_data (provider, BYK_CSS, -1, NULL);
    gtk_style_context_add_provider_for_screen (gdk_screen_get_default (),
                                               GTK_STYLE_PROVIDER (provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref (provider);

    /* GNOME finds the dock icon through StartupWMClass; X11 window managers
     * that do not (Xfce, MATE, KDE) read the window's own icon instead. */
    gtk_window_set_default_icon_name ("byakaron");

    /* GSimpleAction rather than GActionEntry: 24.04's GLib added a padding
     * field that 20.04 does not have, so a shared initializer cannot compile
     * against both headers. */
    byk_add_app_action (app, "about", G_CALLBACK (on_about_activate));
    byk_add_app_action (app, "quit", G_CALLBACK (on_quit_activate));

    /* GNOME's standard keys, and the editor's. */
    static const struct { const gchar *action; const gchar *accels[3]; } shortcuts[] = {
        { "app.quit", { "<Control>q", NULL } },
        { "win.preferences('')", { "<Control>comma", NULL } },
        { "win.show-help-overlay", { "<Control>question", NULL } },
        { "spell.open", { "<Control>o", NULL } },
        { "spell.save", { "<Control>s", NULL } },
        { "spell.copy", { "<Control><Shift>c", NULL } },
        { "spell.typing", { "<Control>t", NULL } },
        { "spell.sidebar", { "F9", NULL } },
    };
    for (gsize i = 0; i < G_N_ELEMENTS (shortcuts); i++)
        gtk_application_set_accels_for_action (GTK_APPLICATION (app), shortcuts[i].action,
                                               shortcuts[i].accels);
}

/* Single-instance: a second launch (from the IBus panel's preferences button,
 * say) raises the window that is already open instead of opening another. */
static void
byk_app_present (GtkApplication *app, const gchar *page)
{
    GtkWindow *window = gtk_application_get_active_window (app);

    /* The active window may be Preferences; the main one owns it. */
    if (window != NULL && !BYK_IS_WINDOW (window))
        window = gtk_window_get_transient_for (window);
    if (window == NULL || !BYK_IS_WINDOW (window))
        window = GTK_WINDOW (byk_window_new (app));

    gtk_window_present (window);
    if (page != NULL && page[0] != '\0')
        byk_window_show_page (BYK_WINDOW (window), page);
}

static void
on_activate (GApplication *app, gpointer user_data)
{
    (void) user_data;
    byk_app_present (GTK_APPLICATION (app), NULL);
}

/* First launch and `byakaron --page=setup` (IBus Preferences) both land here
 * because G_APPLICATION_HANDLES_COMMAND_LINE is set. */
static gint
on_command_line (GApplication *app, GApplicationCommandLine *cmdline, gpointer user_data)
{
    GVariantDict *options = g_application_command_line_get_options_dict (cmdline);
    const gchar *page = NULL;
    (void) user_data;

    g_variant_dict_lookup (options, "page", "&s", &page);
    byk_app_present (GTK_APPLICATION (app), page);
    return 0;
}

int
main (int argc, char *argv[])
{
    byk_prefs_init_schema_dir ();

    GtkApplication *app = gtk_application_new (BYK_APP_ID,
                                               G_APPLICATION_HANDLES_COMMAND_LINE);

    g_application_add_main_option_entries (G_APPLICATION (app), extra_options);
    g_signal_connect (app, "handle-local-options",
                      G_CALLBACK (on_handle_local_options), NULL);
    g_signal_connect (app, "startup", G_CALLBACK (on_startup), NULL);
    g_signal_connect (app, "activate", G_CALLBACK (on_activate), NULL);
    g_signal_connect (app, "command-line", G_CALLBACK (on_command_line), NULL);

    const int status = g_application_run (G_APPLICATION (app), argc, argv);
    g_object_unref (app);

    return status == 0 ? EXIT_SUCCESS : status;
}
