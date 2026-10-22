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
 * apps/linux/scripts/dev_run.sh, which this test's runner starts for it.
 */
#include <glib/gstdio.h>
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
static gboolean g_cursor_visible = FALSE;
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
    g_cursor_visible = table ? ibus_lookup_table_is_cursor_visible (table) : FALSE;
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
    g_cursor_visible = FALSE;
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

/*
 * Name of the engine behind `ctx` once the daemon has started one, polling for
 * up to 20 s. set_engine is asynchronous: the daemon asks the factory for an
 * instance, and on GitHub's arm64 runner that took 6 s, longer than pump()'s
 * 3 s cap, so a single check saw the placeholder "dummy" engine.
 */
static const gchar *
wait_for_engine (IBusInputContext *ctx, const gchar *want)
{
    const gchar *name = NULL;
    for (guint waited_ms = 0; waited_ms <= 20000; waited_ms += 250) {
        IBusEngineDesc *desc = ibus_input_context_get_engine (ctx);
        name = desc ? ibus_engine_desc_get_name (desc) : NULL;
        if (g_strcmp0 (name, want) == 0)
            break;
        g_usleep (250 * 1000);
        pump ();
    }
    return name;
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

    const gchar *engine_ok = wait_for_engine (ctx, "byakaron");
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
    /* Space commits Avro's highlighted candidate: সোনার, not the plain সনার. */
    check ("committed text", g_committed, "আমার সোনার বাংলা ");

    /* PREEDIT_COMMIT: the daemon commits the pending word, the engine only
     * forgets it. Both committing would read আমিআমি. */
    g_print ("reset / focus-out commit the pending word once:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    ibus_input_context_reset (ctx);
    pump ();
    check ("reset commits once", g_committed, "আমি");
    check ("preedit cleared", g_preedit, "");

    reset_state (ctx);
    send_string (ctx, "bangla");
    ibus_input_context_focus_out (ctx);
    pump ();
    check ("focus-out commits once", g_committed, "বাংলা");
    ibus_input_context_focus_in (ctx);
    pump ();

    /*
     * Qt commits the pending word itself on a click, then resets, so the
     * daemon must not commit it too ("ami" + click -> আমিআমি in a Qt app).
     * The engine learns the client name from focus_in_id, which needs IBus
     * 1.5.27+; older libibus has no has-focus-id and is skipped, not passed.
     */
    GObjectClass *engine_class = g_type_class_ref (IBUS_TYPE_ENGINE);
    const gboolean has_focus_id = g_object_class_find_property (engine_class, "has-focus-id") != NULL;
    g_type_class_unref (engine_class);

    g_print ("Qt client keeps the pending word itself:\n");
    if (!has_focus_id) {
        g_print ("  skip (libibus has no has-focus-id)\n");
    } else {
        IBusInputContext *qt = ibus_bus_create_input_context (g_bus, "QIBusInputContext");
        g_signal_connect (qt, "update-preedit-text", G_CALLBACK (on_update_preedit), NULL);
        g_signal_connect (qt, "hide-preedit-text", G_CALLBACK (on_hide_preedit), NULL);
        g_signal_connect (qt, "commit-text", G_CALLBACK (on_commit), NULL);
        ibus_input_context_set_capabilities (qt, IBUS_CAP_PREEDIT_TEXT | IBUS_CAP_FOCUS);
        ibus_input_context_focus_in (qt);
        ibus_input_context_set_engine (qt, "byakaron");
        pump ();
        wait_for_engine (qt, "byakaron");

        reset_state (qt);
        send_string (qt, "ami");
        check ("Qt preedit", g_preedit, "আমি");
        ibus_input_context_reset (qt);
        pump ();
        check ("daemon does not commit for Qt", g_committed, "");

        ibus_input_context_focus_out (qt);
        ibus_input_context_focus_in (ctx);
        ibus_input_context_set_engine (ctx, "byakaron");
        pump ();
        wait_for_engine (ctx, "byakaron");
        g_object_unref (qt);

        reset_state (ctx);
        send_string (ctx, "ami");
        ibus_input_context_reset (ctx);
        pump ();
        check ("other clients still commit once", g_committed, "আমি");
    }

    /*
     * Candidates. Only Avro's first candidate for "ami" is pinned to a literal;
     * the rest are checked against the list the daemon reported, so these
     * assertions test the selection, memory and paging machinery and do not
     * break when the dictionary changes.
     */
    g_print ("candidates appear while typing:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    check_flag ("lookup table shown", g_table_visible, TRUE);
    check ("first candidate is Avro's best", candidate_at (0), "আমি");
    check_flag ("highlight on the first", g_cursor_visible && g_cursor_pos == 0, TRUE);
    send_key (ctx, IBUS_KEY_Escape);

    /* "amar" from here on, so the choices Avro remembers for it do not change
     * what later "ami" tests commit. */
    g_print ("number key selects a candidate, and Avro remembers it:\n");
    reset_state (ctx);
    send_string (ctx, "amar");
    {
        gchar *second = g_strdup (candidate_at (1));
        send_key (ctx, IBUS_KEY_2);
        check ("\"2\" commits candidate 2", g_committed, second);
        check ("preedit cleared", g_preedit, "");
        check_flag ("lookup table hidden", g_table_visible, FALSE);

        reset_state (ctx);
        send_string (ctx, "amar");
        check_flag ("opens on candidate 2 next time", g_cursor_visible && g_cursor_pos == 1, TRUE);
        gchar *spaced = g_strconcat (second, " ", NULL);
        send_key (ctx, IBUS_KEY_space);
        check ("Space commits the highlight", g_committed, spaced);
        g_free (spaced);
        g_free (second);
    }

    g_print ("arrow keys move the highlight (wrapping), Enter picks it:\n");
    reset_state (ctx);
    send_string (ctx, "amar");
    {
        gchar *first = g_strdup (candidate_at (0));
        send_key (ctx, IBUS_KEY_Up);
        check ("Up from the first wraps to the last", g_preedit,
               candidate_at (g_cursor_pos));
        check_flag ("…which is not the first", g_strcmp0 (g_preedit, first) != 0, TRUE);
        send_key (ctx, IBUS_KEY_Down);
        check ("Down wraps back to the first", g_preedit, first);
        g_free (first);
        gchar *third = g_strdup (candidate_at (2));
        send_key (ctx, IBUS_KEY_Down);
        send_key (ctx, IBUS_KEY_Down);
        check_flag ("highlight on candidate 3", g_cursor_visible && g_cursor_pos == 2, TRUE);
        check ("inline text is the highlight", g_preedit, third);
        send_key (ctx, IBUS_KEY_Return);
        /* newline_on_enter is off by default: the word only, Enter consumed. */
        check ("Enter commits the highlight only", g_committed, third);
        check ("preedit cleared", g_preedit, "");
        g_free (third);
    }

    /* Corrections come from the engine's worker thread a moment after the
     * keystroke, with no further key: wait for the list rather than one pump.
     * "bangl" is Avro's বাংল alone (no dictionary word is close), which is
     * when corrections are offered, after it. */
    g_print ("spelling corrections in the candidate list:\n");
    {
        const gchar *env_db = g_getenv ("BYAKARON_SPELL_DB");
        const gboolean have_db = (env_db != NULL && g_file_test (env_db, G_FILE_TEST_EXISTS)) ||
                                 g_file_test ("/usr/share/byakaron/spell.db", G_FILE_TEST_EXISTS);
        if (!have_db) {
            g_print ("  skip (no spell.db for the engine)\n");
        } else {
            reset_state (ctx);
            send_string (ctx, "bangl");
            for (guint waited = 0; waited < 5000 && candidate_count () < 2; waited += 100) {
                g_usleep (100 * 1000);
                pump ();
            }
            guint at = 0;
            for (guint i = 1; i < g_page_size && candidate_at (i) != NULL; i++)
                if (g_strcmp0 (candidate_at (i), "বাংলা") == 0)
                    at = i;
            check ("Avro's word stays first", candidate_at (0), "বাংল");
            check_flag ("correction বাংলা offered", at > 0, TRUE);
            if (at > 0) {
                send_key (ctx, IBUS_KEY_1 + at);
                check ("its number commits it", g_committed, "বাংলা");
            } else {
                send_key (ctx, IBUS_KEY_Escape);
            }
        }
    }

    /* The app saves a word while the engine is running; the engine's composer
     * re-reads the data directory when the next word starts and suggests it. */
    g_print ("personal dictionary reaches the keyboard:\n");
    {
        const gchar *data_dir = g_getenv ("BYAKARON_DATA_DIR");
        if (data_dir == NULL || *data_dir == '\0') {
            g_print ("  skip (BYAKARON_DATA_DIR not set; run via test_ime.sh)\n");
        } else {
            gchar *dict = g_build_filename (data_dir, "user-words.txt", NULL);
            g_file_set_contents (dict, "জিবন\n", -1, NULL);
            reset_state (ctx);
            send_string (ctx, "jib");
            gboolean found = FALSE;
            for (guint i = 0; i < 3 && candidate_at (i) != NULL; i++)
                found = found || g_strcmp0 (candidate_at (i), "জিবন") == 0;
            check_flag ("saved word suggested for jib", found, TRUE);
            send_key (ctx, IBUS_KEY_Escape);
            g_remove (dict);
            g_free (dict);
        }
    }

    /* The table holds only the current page; the composer pages. */
    g_print ("page down moves which candidates 1-9 mean:\n");
    reset_state (ctx);
    send_string (ctx, "bhalo"); /* more than one page of candidates */
    {
        gchar *page_one_first = g_strdup (candidate_at (0));
        send_key (ctx, IBUS_KEY_Page_Down);
        check_flag ("still shown after Page Down", g_table_visible, TRUE);
        check_flag ("a different page", g_strcmp0 (candidate_at (0), page_one_first) != 0, TRUE);
        check_flag ("highlight on its first", g_cursor_pos == 0, TRUE);
        gchar *page_two_first = g_strdup (candidate_at (0));
        send_key (ctx, IBUS_KEY_1);
        check ("\"1\" commits page two's first", g_committed, page_two_first);
        g_free (page_two_first);
        g_free (page_one_first);
    }

    g_print ("no candidates for a word outside the lexicon:\n");
    reset_state (ctx);
    /* Avro has only the transliteration for it, and spell.db has no
     * correction close to it either. */
    send_string (ctx, "jhjh");
    for (guint waited = 0; waited < 1000; waited += 100) {
        g_usleep (100 * 1000);
        pump ();
    }
    check ("preedit still transliterates", g_preedit, "ঝঝ");
    check_flag ("lookup table hidden", g_table_visible, FALSE);

    g_print ("escape drops the candidates with the word:\n");
    reset_state (ctx);
    send_string (ctx, "ami");
    send_key (ctx, IBUS_KEY_Escape);
    check_flag ("lookup table hidden", g_table_visible, FALSE);
    check ("preedit cleared", g_preedit, "");
    check ("nothing committed", g_committed, "");

    g_print ("space commits the highlighted candidate, as Avro does:\n");
    reset_state (ctx);
    /* Avro's first candidate (সোনার) differs from the plain transliteration
     * (সনার); the inline text is the highlighted candidate, not the latter. */
    send_string (ctx, "sonar");
    check_flag ("candidates offered", g_table_visible, TRUE);
    check ("inline text is the highlight", g_preedit, "সোনার");
    send_key (ctx, IBUS_KEY_space);
    check ("committed the highlight", g_committed, "সোনার ");

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
