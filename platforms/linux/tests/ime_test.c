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

/*
 * Latest candidate list seen. The daemon only routes the lookup table to the
 * client when the client claims IBUS_CAP_LOOKUP_TABLE — otherwise it goes to the
 * desktop panel and never reaches us. Set in main() alongside the other caps.
 */
static gchar **g_candidates = NULL; /* NULL-terminated */
static guint g_page_size = 0;
static guint g_cursor_pos = 0;
static gboolean g_table_visible = FALSE;

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
 * Copy the candidate list out of the table.
 *
 * The table is floating and released once the signal returns, so the strings
 * have to be taken now rather than kept by reference.
 */
static void
on_update_lookup_table (IBusInputContext *context,
                        IBusLookupTable  *table,
                        gboolean          visible,
                        gpointer          user_data)
{
    (void) context; (void) user_data;

    g_strfreev (g_candidates);

    const guint n = table ? ibus_lookup_table_get_number_of_candidates (table) : 0;
    GPtrArray *words = g_ptr_array_new ();
    for (guint i = 0; i < n; i++) {
        IBusText *candidate = ibus_lookup_table_get_candidate (table, i);
        g_ptr_array_add (words, g_strdup (candidate ? ibus_text_get_text (candidate) : ""));
    }
    g_ptr_array_add (words, NULL);

    g_candidates = (gchar **) g_ptr_array_free (words, FALSE);
    g_page_size = table ? ibus_lookup_table_get_page_size (table) : 0;
    g_cursor_pos = table ? ibus_lookup_table_get_cursor_pos (table) : 0;
    g_table_visible = visible;
}

static void
on_hide_lookup_table (IBusInputContext *context, gpointer user_data)
{
    (void) context; (void) user_data;
    g_table_visible = FALSE;
}

/* Candidate at `index`, or NULL if the list is shorter than that. */
static const gchar *
candidate_at (guint index)
{
    if (g_candidates == NULL)
        return NULL;
    for (guint i = 0; i < index; i++) {
        if (g_candidates[i] == NULL)
            return NULL;
    }
    return g_candidates[index];
}

static guint
candidate_count (void)
{
    return g_candidates ? (guint) g_strv_length (g_candidates) : 0;
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
    g_strfreev (g_candidates); g_candidates = NULL;
    g_page_size = 0;
    g_cursor_pos = 0;
    g_table_visible = FALSE;
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

static void
check_flag (const char *what, gboolean got, gboolean want)
{
    const gboolean ok = (!!got == !!want);
    g_print ("  %-4s %-34s -> %s\n", ok ? "ok" : "FAIL", what, got ? "yes" : "no");
    if (!ok) {
        g_print ("       expected: %s\n", want ? "yes" : "no");
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
    g_signal_connect (ctx, "update-lookup-table", G_CALLBACK (on_update_lookup_table), NULL);
    g_signal_connect (ctx, "hide-lookup-table", G_CALLBACK (on_hide_lookup_table), NULL);

    ibus_input_context_set_capabilities (ctx, IBUS_CAP_PREEDIT_TEXT |
                                             IBUS_CAP_LOOKUP_TABLE |
                                             IBUS_CAP_FOCUS);
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

    /*
     * Candidates. Only the first candidate is pinned to a literal, because that
     * one is a real guarantee: the word actually typed has to rank first, or
     * pressing "1" would change what the user wrote. The rest are checked
     * against the list the daemon reported, so these assertions test the
     * selection and paging machinery and do not break when the lexicon grows.
     */
    g_print ("candidates appear while typing:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    check_flag ("lookup table shown", g_table_visible, TRUE);
    check ("first candidate is the typed word", candidate_at (0), "আমি");
    check_flag ("more than one page offered", candidate_count () > g_page_size, TRUE);

    g_print ("number key selects a candidate:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    {
        gchar *second = g_strdup (candidate_at (1));
        send_key (ctx, IBUS_KEY_2);
        check ("\"2\" commits candidate 2", g_committed, second);
        check ("preedit cleared", g_preedit, "");
        check_flag ("lookup table hidden", g_table_visible, FALSE);
        g_free (second);
    }

    g_print ("page down moves which candidates 1-9 mean:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    {
        /* First entry of page two, which "1" must select once we are there. */
        gchar *next_page_first = g_strdup (candidate_at (g_page_size));
        send_key (ctx, IBUS_KEY_Page_Down);
        check_flag ("still shown after Page Down", g_table_visible, TRUE);
        check_flag ("cursor moved to page two", g_cursor_pos == g_page_size, TRUE);
        send_key (ctx, IBUS_KEY_1);
        check ("\"1\" commits page two's first", g_committed, next_page_first);
        g_free (next_page_first);
    }

    g_print ("no candidates for a word outside the lexicon:\n");
    reset_state (ctx);
    /* Real Bangla, but not a dictionary lemma. */
    send_string (ctx, "sonar");
    check ("preedit still transliterates", g_preedit, "সনার");
    check_flag ("lookup table hidden", g_table_visible, FALSE);

    g_print ("escape drops the candidates with the word:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    send_key (ctx, IBUS_KEY_Escape);
    check_flag ("lookup table hidden", g_table_visible, FALSE);
    check ("preedit cleared", g_preedit, "");
    check ("nothing committed", g_committed, "");

    g_print ("space commits what was typed, not a candidate:\n");
    reset_state (ctx);
    /* "bangl" is a prefix, not a word: its first candidate (বাংলা) differs from
     * the preedit (বাংল), which is what gives this assertion teeth. */
    send_string (ctx, "bangl");
    check_flag ("candidates offered", g_table_visible, TRUE);
    check ("first candidate differs from preedit",
           g_strcmp0 (candidate_at (0), g_preedit) != 0 ? "differs" : "same", "differs");
    send_key (ctx, IBUS_KEY_space);
    check ("committed the typed word", g_committed, "বাংল ");

    g_print ("digits become Bangla numerals:\n");
    reset_state (ctx);
    send_string (ctx, "1");
    check ("type \"1\"", g_preedit, "১");
    reset_state (ctx);
    send_string (ctx, "0");
    check ("type \"0\"", g_preedit, "০");
    reset_state (ctx);
    send_string (ctx, "2024");
    check ("type \"2024\"", g_preedit, "২০২৪");
    reset_state (ctx);
    /* `0` is not a candidate selector, so it still types a numeral even while
     * the list is up (`1`–`9` would pick instead). */
    send_string (ctx, "ami0");
    check ("\"ami\" then \"0\"", g_preedit, "আমি০");

    g_print ("punctuation stays in the latin buffer:\n");
    reset_state (ctx);
    send_string (ctx, ".");
    check ("type \".\"", g_preedit, "।");
    reset_state (ctx);
    send_string (ctx, "ami.");
    check ("type \"ami.\"", g_preedit, "আমি।");
    send_key (ctx, IBUS_KEY_space);
    check ("space commits dari", g_committed, "আমি। ");

    ibus_input_context_focus_out (ctx);
    g_object_unref (ctx);

    g_print ("\n%s (%d failure%s)\n",
             g_failures ? "IME TEST FAILED" : "ime test passed",
             g_failures, g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}
