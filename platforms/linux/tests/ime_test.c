/*
 * End-to-end test for the Byakaron IBus engine.
 *
 * Creates its own IBus input context, switches *that context only* to the
 * byakaron engine, and feeds it key events over D-Bus exactly as an application
 * would. The preedit and commit signals coming back are the same ones a text
 * field would receive, so this exercises the real engine in the real daemon
 * without touching the desktop's active input source.
 *
 * Requires a running ibus-daemon with the engine registered — see
 * platforms/linux/scripts/dev_run.sh, which this test's runner starts for it.
 */
#include <ibus.h>
#include <locale.h>
#include <stdlib.h>
#include <string.h>

/* Latest preedit / commit seen, owned here and replaced as signals arrive. */
static gchar *g_preedit = NULL;
static gchar *g_committed = NULL;
static IBusBus *g_bus = NULL;
static int g_failures = 0;

static void
on_update_preedit (IBusInputContext *context,
                   IBusText         *text,
                   guint             cursor_pos,
                   gboolean          visible,
                   gpointer          user_data)
{
    (void) context; (void) cursor_pos; (void) user_data;
    g_free (g_preedit);
    g_preedit = g_strdup (visible && text ? ibus_text_get_text (text) : "");
}

static void
on_hide_preedit (IBusInputContext *context, gpointer user_data)
{
    (void) context; (void) user_data;
    g_free (g_preedit);
    g_preedit = g_strdup ("");
}

static void
on_commit (IBusInputContext *context, IBusText *text, gpointer user_data)
{
    (void) context; (void) user_data;
    /* Commits accumulate the way they would in a real text field. */
    gchar *joined = g_strconcat (g_committed ? g_committed : "",
                                 text ? ibus_text_get_text (text) : "", NULL);
    g_free (g_committed);
    g_committed = joined;
}

/*
 * Let queued D-Bus signals be delivered before we read the results.
 *
 * Signals arrive asynchronously, so a fixed iteration count is flaky under
 * load (observed: the last commit of a multi-word sentence occasionally not
 * having landed yet). Drain the main context until it goes quiet for a short
 * stretch, bounded by a generous overall cap so a stuck daemon cannot hang
 * the test forever.
 */
static void
pump (void)
{
    const gint64 quiet_period = 30 * 1000;          /* 30ms with no events */
    const gint64 deadline = g_get_monotonic_time () + 3 * G_TIME_SPAN_SECOND;
    gint64 quiet_since = g_get_monotonic_time ();

    while (g_get_monotonic_time () < deadline) {
        if (g_main_context_iteration (NULL, FALSE)) {
            quiet_since = g_get_monotonic_time ();
            continue;
        }
        if (g_get_monotonic_time () - quiet_since >= quiet_period)
            break;
        g_usleep (1000);
    }
}

static void
send_key (IBusInputContext *ctx, guint keyval)
{
    /* keycode 0 is fine: the engine reads keyval, which is already
     * layout-resolved. Press then release, as a real keyboard sends. */
    ibus_input_context_process_key_event (ctx, keyval, 0, 0);
    ibus_input_context_process_key_event (ctx, keyval, 0, IBUS_RELEASE_MASK);
    pump ();
}

static void
send_string (IBusInputContext *ctx, const char *ascii)
{
    for (const char *p = ascii; *p; p++)
        send_key (ctx, (guint) (unsigned char) *p);
}

static void
reset_state (IBusInputContext *ctx)
{
    ibus_input_context_reset (ctx);
    pump ();
    g_free (g_preedit);    g_preedit = NULL;
    g_free (g_committed);  g_committed = NULL;
}

static void
check (const char *what, const char *got, const char *want)
{
    const gboolean ok = g_strcmp0 (got ? got : "", want) == 0;
    g_print ("  %-4s %-34s -> %s\n", ok ? "ok" : "FAIL", what, got ? got : "(none)");
    if (!ok) {
        g_print ("       expected: %s\n", want);
        g_failures++;
    }
}

int
main (void)
{
    /* Without this the C locale stays ASCII and g_print renders every
     * Bangla character as "?", which makes a passing run look broken. */
    setlocale (LC_ALL, "");

    ibus_init ();

    g_bus = ibus_bus_new ();
    if (!ibus_bus_is_connected (g_bus)) {
        g_printerr ("ime_test: ibus-daemon not reachable\n");
        return 77; /* skip */
    }

    IBusInputContext *ctx = ibus_bus_create_input_context (g_bus, "byakaron-test");
    if (ctx == NULL) {
        g_printerr ("ime_test: could not create an input context\n");
        return 1;
    }

    g_signal_connect (ctx, "update-preedit-text", G_CALLBACK (on_update_preedit), NULL);
    g_signal_connect (ctx, "hide-preedit-text", G_CALLBACK (on_hide_preedit), NULL);
    g_signal_connect (ctx, "commit-text", G_CALLBACK (on_commit), NULL);

    ibus_input_context_set_capabilities (ctx, IBUS_CAP_PREEDIT_TEXT | IBUS_CAP_FOCUS);
    ibus_input_context_focus_in (ctx);
    ibus_input_context_set_engine (ctx, "byakaron");
    pump ();

    const gchar *engine_ok = NULL;
    IBusEngineDesc *desc = ibus_input_context_get_engine (ctx);
    engine_ok = desc ? ibus_engine_desc_get_name (desc) : NULL;
    if (g_strcmp0 (engine_ok, "byakaron") != 0) {
        g_printerr ("ime_test: context engine is '%s', not 'byakaron' — "
                    "is dev_run.sh running?\n", engine_ok ? engine_ok : "(none)");
        return 77; /* skip rather than fail: the engine was never reachable */
    }

    g_print ("preedit while typing:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    check ("type \"ami\"", g_preedit, "আমি");

    reset_state (ctx);
    send_string (ctx, "bangla");
    check ("type \"bangla\"", g_preedit, "বাংলা");

    g_print ("backspace re-transliterates:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    send_key (ctx, IBUS_KEY_BackSpace);
    /* Dropping the latin 'i' must leave the Bangla for "am", not a half-formed
     * conjunct, which is the whole reason the latin buffer is authoritative. */
    check ("\"ami\" then Backspace", g_preedit, "আম");

    g_print ("space commits the word:\n");
    reset_state (ctx);
    send_string (ctx, "ami ");
    check ("committed text", g_committed, "আমি ");
    check ("preedit cleared", g_preedit, "");

    g_print ("escape discards:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    send_key (ctx, IBUS_KEY_Escape);
    check ("preedit cleared", g_preedit, "");
    check ("nothing committed", g_committed, "");

    g_print ("multi-word sentence:\n");
    reset_state (ctx);
    send_string (ctx, "amar sonar bangla ");
    check ("committed text", g_committed, "আমার সনার বাংলা ");

    ibus_input_context_focus_out (ctx);
    g_object_unref (ctx);

    g_print ("\n%s (%d failure%s)\n",
             g_failures ? "IME TEST FAILED" : "ime test passed",
             g_failures, g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}
