/*
 * byakaron — the GTK4 / libadwaita companion app to the input method.
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
#include "window.h"

/*
 * Type sizes and the step badge, the only things a stylesheet is needed for.
 *
 * Bangla needs more room than the default 1rem body text to stay legible at a
 * glance, and the composer's preedit is the one piece of text the user is
 * actually watching, so it gets the largest size. Everything else is left to
 * libadwaita's own classes, which is also what keeps this working under a
 * user's own accent colour and dark mode.
 */
static const char BYK_CSS[] =
    ".byk-bangla { font-size: 1.25rem; }\n"
    ".byk-latin { font-family: monospace; font-size: 1.1rem; padding: 10px 12px; }\n"
    ".byk-preedit { font-size: 1.6rem; padding: 8px 12px; }\n"
    ".byk-preedit-filled { color: @accent_color; }\n"
    ".byk-candidates { padding: 0 12px 10px 12px; }\n"
    ".byk-candidate { font-size: 1.1rem; }\n"
    ".byk-layout-glyph { font-size: 1.15rem; }\n"
    ".byk-step {\n"
    "  min-width: 24px; min-height: 24px;\n"
    "  border-radius: 999px;\n"
    "  background-color: @accent_bg_color;\n"
    "  color: @accent_fg_color;\n"
    "  font-weight: bold;\n"
    "}\n";

static const char *const AUTHORS[] = { "Nurul Huda (Apon)", NULL };

static void
on_about_activate (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
    GtkApplication *app = GTK_APPLICATION (user_data);
    (void) action;
    (void) parameter;

    GtkWidget *about = adw_about_window_new ();

    adw_about_window_set_application_name (ADW_ABOUT_WINDOW (about), "Byakaron");
    adw_about_window_set_application_icon (ADW_ABOUT_WINDOW (about), "byakaron");
    adw_about_window_set_version (ADW_ABOUT_WINDOW (about), BYK_APP_VERSION);
    adw_about_window_set_developer_name (ADW_ABOUT_WINDOW (about), "Nurul Huda (Apon)");
    adw_about_window_set_developers (ADW_ABOUT_WINDOW (about), (const char **) AUTHORS);
    adw_about_window_set_license_type (ADW_ABOUT_WINDOW (about), GTK_LICENSE_MIT_X11);
    adw_about_window_set_website (ADW_ABOUT_WINDOW (about), BYK_URL_WEBSITE);
    adw_about_window_set_issue_url (ADW_ABOUT_WINDOW (about), BYK_URL_GITHUB "/issues");
    adw_about_window_set_comments (
        ADW_ABOUT_WINDOW (about),
        "Bangla phonetic input method and spell checker, over a shared Zig engine.");

    gtk_window_set_transient_for (GTK_WINDOW (about),
                                  gtk_application_get_active_window (app));
    gtk_window_present (GTK_WINDOW (about));
}

static void
on_quit_activate (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
    (void) action;
    (void) parameter;
    g_application_quit (G_APPLICATION (user_data));
}

static const GActionEntry ACTIONS[] = {
    { "about", on_about_activate, NULL, NULL, NULL, { 0, 0, 0 } },
    { "quit", on_quit_activate, NULL, NULL, NULL, { 0, 0, 0 } },
};

static void
on_startup (GApplication *app, gpointer user_data)
{
    (void) user_data;

    GtkCssProvider *provider = gtk_css_provider_new ();
    gtk_css_provider_load_from_string (provider, BYK_CSS);
    gtk_style_context_add_provider_for_display (gdk_display_get_default (),
                                                GTK_STYLE_PROVIDER (provider),
                                                GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref (provider);

    g_action_map_add_action_entries (G_ACTION_MAP (app), ACTIONS, G_N_ELEMENTS (ACTIONS), app);

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
        window = GTK_WINDOW (byk_window_new (ADW_APPLICATION (app)));

    gtk_window_present (window);
}

int
main (int argc, char *argv[])
{
    AdwApplication *app = adw_application_new (BYK_APP_ID, G_APPLICATION_DEFAULT_FLAGS);

    g_signal_connect (app, "startup", G_CALLBACK (on_startup), NULL);
    g_signal_connect (app, "activate", G_CALLBACK (on_activate), NULL);

    const int status = g_application_run (G_APPLICATION (app), argc, argv);
    g_object_unref (app);

    return status == 0 ? EXIT_SUCCESS : status;
}
