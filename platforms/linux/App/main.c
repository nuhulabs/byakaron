/*
 * byakaron — the GTK3 companion app to the input method.
 *
 * GTK3 3.24 is on Ubuntu 20.04, 22.04, and 24.04. GTK4 and libadwaita 1.4 are
 * not, so this app stays on GTK3 rather than shipping a UI that only the
 * newest release can open.
 *
 * Three jobs, in the order a new user meets them: get the keyboard added to
 * their input sources (Setup), let them try Bangla before it is (Write), and
 * check spelling in text they already have (Spelling), with the Avro key map
 * as a reference (Layout).
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
 * stylesheet does not define. Accent colour comes from the theme so a user's
 * own colour and dark mode still apply.
 */
static const char BYK_CSS[] =
    ".heading { font-weight: bold; }\n"
    ".caption { font-size: smaller; }\n"
    ".monospace { font-family: monospace; }\n"
    ".success { color: #26a269; }\n"
    ".warning { color: #e5a50a; }\n"
    ".error { color: #c01c28; }\n"
    ".card { border: 1px solid alpha(@theme_fg_color, 0.15); border-radius: 8px; }\n"
    ".byk-bangla { font-size: 1.25rem; }\n"
    ".byk-latin { font-family: monospace; font-size: 1.1rem; padding: 10px 12px; }\n"
    ".byk-preedit { font-size: 1.6rem; padding: 8px 12px; }\n"
    ".byk-preedit-filled { color: @theme_selected_bg_color; }\n"
    ".byk-candidates { padding: 0 12px 10px 12px; }\n"
    ".byk-candidate { font-size: 1.1rem; }\n"
    ".byk-layout-glyph { font-size: 1.15rem; }\n"
    ".byk-toast { padding: 8px 12px; }\n"
    ".byk-step {\n"
    "  min-width: 24px; min-height: 24px;\n"
    "  border-radius: 999px;\n"
    "  background-color: @theme_selected_bg_color;\n"
    "  color: @theme_selected_fg_color;\n"
    "  font-weight: bold;\n"
    "}\n";

static const char *const AUTHORS[] = { "Nurul Huda (Apon)", NULL };

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
                           "copyright", "Nurul Huda (Apon)",
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

    /* GSimpleAction rather than GActionEntry: 24.04's GLib added a padding
     * field that 20.04 does not have, so a shared initializer cannot compile
     * against both headers. */
    byk_add_app_action (app, "about", G_CALLBACK (on_about_activate));
    byk_add_app_action (app, "quit", G_CALLBACK (on_quit_activate));

    const gchar *quit_accels[] = { "<Control>q", NULL };
    gtk_application_set_accels_for_action (GTK_APPLICATION (app), "app.quit", quit_accels);
}

/* Single-instance: a second launch (from the IBus panel's preferences button,
 * say) raises the window that is already open instead of opening another. */
static void
on_activate (GApplication *app, gpointer user_data)
{
    (void) user_data;

    GtkWindow *window = gtk_application_get_active_window (GTK_APPLICATION (app));

    if (window == NULL)
        window = GTK_WINDOW (byk_window_new (GTK_APPLICATION (app)));

    gtk_window_present (window);
}

int
main (int argc, char *argv[])
{
    byk_prefs_init_schema_dir ();

    GtkApplication *app = gtk_application_new (BYK_APP_ID, G_APPLICATION_FLAGS_NONE);

    g_signal_connect (app, "startup", G_CALLBACK (on_startup), NULL);
    g_signal_connect (app, "activate", G_CALLBACK (on_activate), NULL);

    const int status = g_application_run (G_APPLICATION (app), argc, argv);
    g_object_unref (app);

    return status == 0 ? EXIT_SUCCESS : status;
}
