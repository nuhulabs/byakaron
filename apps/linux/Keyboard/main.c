/*
 * byakaron-ibus — the IBus engine process.
 *
 * Two ways this runs:
 *
 *   byakaron-ibus --ibus
 *       How the IBus daemon starts us, per the <exec> line in the installed
 *       component XML. The component is already known to the daemon, so we only
 *       claim our bus name and serve engines.
 *
 *   byakaron-ibus --xml apps/linux/Resources/byakaron.xml
 *       Development mode: register the component with the running daemon at
 *       runtime, so the engine can be tested without installing anything into
 *       /usr/share. The registration disappears when this process exits.
 */
#include <ibus.h>
#include <stdlib.h>

#include "engine.h"
#include "prefs.h"

#define BYK_BUS_NAME    "org.freedesktop.IBus.Byakaron"
#define BYK_ENGINE_NAME "byakaron"

static IBusBus *bus = NULL;
static IBusFactory *factory = NULL;

static gboolean opt_ibus = FALSE;
static gchar *opt_xml = NULL;

static const GOptionEntry OPTIONS[] = {
    { "ibus", 'i', 0, G_OPTION_ARG_NONE, &opt_ibus,
      "Run as an engine started by the IBus daemon", NULL },
    { "xml", 'x', 0, G_OPTION_ARG_FILENAME, &opt_xml,
      "Register this component XML with the running daemon (development)", "FILE" },
    { NULL }
};

/* If the daemon goes away our engines are meaningless; exit so it can respawn
 * us cleanly rather than leaving a stale process holding the bus name. */
static void
on_disconnected (IBusBus *unused_bus, gpointer user_data)
{
    (void) unused_bus;
    (void) user_data;
    g_message ("byakaron: ibus-daemon disconnected, exiting");
    ibus_quit ();
}

int
main (int argc, char *argv[])
{
    byk_prefs_init_schema_dir ();

    GError *error = NULL;
    GOptionContext *context = g_option_context_new ("- Byakaron Bangla input method");
    g_option_context_add_main_entries (context, OPTIONS, NULL);
    if (!g_option_context_parse (context, &argc, &argv, &error)) {
        g_printerr ("byakaron: %s\n", error->message);
        g_clear_error (&error);
        g_option_context_free (context);
        return EXIT_FAILURE;
    }
    g_option_context_free (context);

    ibus_init ();

    bus = ibus_bus_new ();
    if (!ibus_bus_is_connected (bus)) {
        g_printerr ("byakaron: cannot connect to ibus-daemon — is IBus running?\n");
        return EXIT_FAILURE;
    }
    g_signal_connect (bus, "disconnected", G_CALLBACK (on_disconnected), NULL);

    factory = ibus_factory_new (ibus_bus_get_connection (bus));
    ibus_factory_add_engine (factory, BYK_ENGINE_NAME, BYK_TYPE_ENGINE);

    if (opt_xml != NULL) {
        IBusComponent *component = ibus_component_new_from_file (opt_xml);
        if (component == NULL) {
            g_printerr ("byakaron: could not read component XML: %s\n", opt_xml);
            return EXIT_FAILURE;
        }
        if (!ibus_bus_register_component (bus, component)) {
            g_printerr ("byakaron: failed to register component with ibus-daemon\n");
            return EXIT_FAILURE;
        }
        g_message ("byakaron: registered '%s' from %s", BYK_ENGINE_NAME, opt_xml);
    } else {
        /* Started by the daemon (--ibus) or by hand: claim the well-known name
         * the installed component XML points at. */
        if (!opt_ibus)
            g_message ("byakaron: no --ibus or --xml given, assuming --ibus");
        ibus_bus_request_name (bus, BYK_BUS_NAME, 0);
    }

    ibus_main ();
    return EXIT_SUCCESS;
}
