/*
 * wayland_rdtest <label> <reader-cmd...>: type through
 * org.gnome.Mutter.RemoteDesktop, the compositor's own input path, and check
 * what the app received (the reader prints its text, e.g. `cat <outfile>` for
 * wayland_textapp). One D-Bus connection holds the session: it ends when the
 * connection that created it closes.
 *
 * Run by `zig build linux-wayland-e2e` (src/build/linux.zig) on a private
 * headless GNOME Shell. Exit status: 0 when every check passed.
 */
#include <gio/gio.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RD "org.gnome.Mutter.RemoteDesktop"
#define RD_SESSION RD ".Session"

#define KS_BACKSPACE 0xff08
#define KS_RETURN 0xff0d
#define KS_DOWN 0xff54
#define KS_CONTROL_L 0xffe3
#define BTN_LEFT 272

static GDBusConnection *g_bus = NULL;
static char *g_session = NULL;
static const char *g_label = NULL;
static char **g_reader = NULL;
static char *g_data = NULL;
static int g_fails = 0;

static void
sleep_s (double s)
{
    g_usleep ((gulong) (s * G_USEC_PER_SEC));
}

static GVariant *
call (const char *path, const char *iface, const char *method, GVariant *params)
{
    GError *err = NULL;
    GVariant *r = g_dbus_connection_call_sync (g_bus, RD, path, iface, method, params,
                                               NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);
    if (r == NULL) {
        printf ("  FAIL %s %s.%s: %s\n", g_label, iface, method, err->message);
        fflush (stdout);
        exit (1);
    }
    return r;
}

static void
session_call (const char *method, GVariant *params)
{
    g_variant_unref (call (g_session, RD_SESSION, method, params));
}

static void
sym (guint32 keysym, gboolean down)
{
    session_call ("NotifyKeyboardKeysym", g_variant_new ("(ub)", keysym, down));
}

static void
key (guint32 keysym)
{
    sym (keysym, TRUE);
    sleep_s (0.03);
    sym (keysym, FALSE);
    sleep_s (0.06);
}

/* ASCII only: a Latin-1 keysym is the character's code point. */
static void
typ (const char *s)
{
    for (; *s; s++) key ((guint32) (unsigned char) *s);
}

static void
ctrl (char c)
{
    sym (KS_CONTROL_L, TRUE);
    key ((guint32) (unsigned char) c);
    sym (KS_CONTROL_L, FALSE);
    sleep_s (0.1);
}

static void
click (void)
{
    for (int i = 0; i < 2; i++) {
        session_call ("NotifyPointerButton", g_variant_new ("(ib)", BTN_LEFT, i == 0));
        sleep_s (0.05);
    }
    sleep_s (0.3);
}

/* What the app holds now, as the reader prints it. */
static char *
text (void)
{
    char *out = NULL;
    GError *err = NULL;
    if (!g_spawn_sync (NULL, g_reader, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_STDERR_TO_DEV_NULL,
                       NULL, NULL, &out, NULL, NULL, &err)) {
        fprintf (stderr, "  note %s reader failed: %s\n", g_label, err->message);
        g_error_free (err);
        return g_strdup ("");
    }
    return out != NULL ? out : g_strdup ("");
}

/* Avro remembers each pick and opens the word on it next time; start every
 * check from Avro's own order. The engine re-reads the file when a word starts. */
static void
forget (void)
{
    g_mkdir_with_parents (g_data, 0755);
    char *path = g_build_filename (g_data, "selections.json", NULL);
    g_file_set_contents (path, "{}", -1, NULL);
    g_free (path);
}

typedef void (*Action) (void);

static char *
run (Action action)
{
    forget ();
    ctrl ('a');
    key (KS_BACKSPACE);
    sleep_s (0.4);
    action ();
    sleep_s (1.2);
    return text ();
}

static void
report (const char *name, const char *got, gboolean ok, const char *exp)
{
    if (!ok) g_fails++;
    if (ok)
        printf ("  ok   %s %s -> [%s]\n", g_label, name, got);
    else
        printf ("  FAIL %s %s -> [%s] expected [%s]\n", g_label, name, got, exp);
    fflush (stdout);
}

static void
t (const char *name, const char *exp, Action action)
{
    char *got = run (action);
    report (name, got, strcmp (got, exp) == 0, exp);
    g_free (got);
}

/* A new window does not always get keyboard focus: on GitHub's runner GNOME
 * Shell left it unfocused, so keys went nowhere until the first click (the
 * click-commit check). Click into it, the way a user clicks into a text box,
 * then type until the whole path to IBus answers. */
static gboolean
warm_up (double limit)
{
    const gint64 start = g_get_monotonic_time ();
    GPtrArray *seen = g_ptr_array_new_with_free_func (g_free);
    gboolean ready = FALSE;
    forget ();
    while ((g_get_monotonic_time () - start) / (double) G_USEC_PER_SEC < limit) {
        click ();
        ctrl ('a');
        key (KS_BACKSPACE);
        sleep_s (0.3);
        typ ("ami ");
        sleep_s (1.0);
        char *got = text ();
        if (strcmp (got, "আমি ") == 0) {
            printf ("  info %s ready after %.1f s\n", g_label,
                    (g_get_monotonic_time () - start) / (double) G_USEC_PER_SEC);
            fflush (stdout);
            g_free (got);
            ready = TRUE;
            break;
        }
        g_ptr_array_add (seen, got);
        sleep_s (1.0);
    }
    if (!ready) {
        printf ("  info %s warm-up saw:", g_label);
        for (guint i = 0; i < seen->len; i++) {
            if (i >= 3 && i + 2 < seen->len) {
                if (i == 3) printf (" ...");
                continue;
            }
            printf (" [%s]", (const char *) g_ptr_array_index (seen, i));
        }
        printf ("\n");
        fflush (stdout);
    }
    g_ptr_array_unref (seen);
    return ready;
}

/* Settings apply from the next word: flip one in settings.json (what the app
 * writes through its composer) while the keyboard runs. */

/* End of the JSON value starting at s[i] (whitespace skipped), or -1. Enough of
 * JSON to step over any value: strings, nested objects/arrays, literals. */
static long
json_skip_value (const char *s, long i)
{
    int depth = 0;
    gboolean in_str = FALSE;
    while (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') i++;
    const long begin = i;
    for (; s[i]; i++) {
        const char c = s[i];
        if (in_str) {
            if (c == '\\' && s[i + 1]) i++;
            else if (c == '"') {
                in_str = FALSE;
                if (depth == 0) return i + 1;
            }
            continue;
        }
        if (c == '"') in_str = TRUE;
        else if (c == '{' || c == '[') depth++;
        else if (c == '}' || c == ']') {
            if (depth == 0) return i > begin ? i : -1; /* end of the enclosing object */
            if (--depth == 0) return i + 1;
        } else if (c == ',' && depth == 0) return i > begin ? i : -1;
    }
    return depth == 0 && !in_str && i > begin ? i : -1;
}

/* settings.json with "<name>": value (true/false) set, every other top-level
 * member kept as written. An unreadable or non-object file starts from {}. */
static char *
json_set_bool (const char *json, const char *name, gboolean value)
{
    GString *out = g_string_new ("{");
    gboolean first = TRUE, done = FALSE;
    char *want = g_strdup_printf ("\"%s\"", name);
    long i = 0;
    while (json && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r')) i++;
    if (json && json[i] == '{') {
        GString *members = g_string_new ("");
        gboolean ok = TRUE, members_first = TRUE;
        i++;
        for (;;) {
            while (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r') i++;
            if (json[i] == '}') break;
            if (json[i] != '"') { ok = FALSE; break; }
            const long key_start = i;
            const long key_end = json_skip_value (json, i);
            if (key_end < 0) { ok = FALSE; break; }
            i = key_end;
            while (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r') i++;
            if (json[i] != ':') { ok = FALSE; break; }
            i++;
            while (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r') i++;
            const long val_start = i;
            const long val_end = json_skip_value (json, i);
            if (val_end < 0) { ok = FALSE; break; }
            i = val_end;
            if (!members_first) g_string_append (members, ", ");
            members_first = FALSE;
            g_string_append_len (members, json + key_start, key_end - key_start);
            g_string_append (members, ": ");
            if ((size_t) (key_end - key_start) == strlen (want) &&
                strncmp (json + key_start, want, key_end - key_start) == 0) {
                g_string_append (members, value ? "true" : "false");
                done = TRUE;
            } else {
                long e = val_end;
                while (e > val_start && (json[e - 1] == ' ' || json[e - 1] == '\t' ||
                                         json[e - 1] == '\n' || json[e - 1] == '\r')) e--;
                g_string_append_len (members, json + val_start, e - val_start);
            }
            while (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r') i++;
            if (json[i] == ',') { i++; continue; }
            if (json[i] == '}') break;
            ok = FALSE;
            break;
        }
        if (ok) {
            g_string_append (out, members->str);
            first = members_first;
        } else {
            done = FALSE;
        }
        g_string_free (members, TRUE);
    }
    if (!done) {
        if (!first) g_string_append (out, ", ");
        g_string_append_printf (out, "%s: %s", want, value ? "true" : "false");
    }
    g_string_append (out, "}");
    g_free (want);
    return g_string_free (out, FALSE);
}

static void
setting (const char *name, gboolean value)
{
    char *path = g_build_filename (g_data, "settings.json", NULL);
    char *old = NULL;
    if (!g_file_get_contents (path, &old, NULL, NULL)) old = NULL;
    char *json = json_set_bool (old, name, value);
    g_mkdir_with_parents (g_data, 0755);
    GError *err = NULL;
    if (!g_file_set_contents (path, json, -1, &err)) {
        fprintf (stderr, "  note %s cannot write %s: %s\n", g_label, path, err->message);
        g_error_free (err);
    }
    g_free (json);
    g_free (old);
    g_free (path);
    sleep_s (0.5);
}

/* The actions each check types. */
static void act_ami_bangla (void) { typ ("ami bangla "); }
static void act_bhalo (void) { typ ("bhalO. "); }
static void act_2026 (void) { typ ("2026 "); }
static void act_pick2 (void) { typ ("ami"); sleep_s (0.4); key ('2'); }
static void act_pick3 (void) { typ ("ami"); sleep_s (0.4); key ('3'); }
static void act_remember (void) { typ ("ami"); sleep_s (0.4); key ('2'); sleep_s (0.3); typ (" ami "); }
static void act_click_commit (void) { typ ("ami"); sleep_s (0.4); click (); }
static void act_down_down_enter (void)
{
    typ ("ami");
    sleep_s (0.4);
    key (KS_DOWN);
    key (KS_DOWN);
    sleep_s (0.2);
    key (KS_RETURN);
}
static void act_sonar (void) { typ ("sonar "); }

int
main (int argc, char *argv[])
{
    setlocale (LC_ALL, "");
    if (argc < 3) {
        fprintf (stderr, "usage: %s <label> <reader-cmd...>\n", argv[0]);
        return 2;
    }
    g_label = argv[1];
    g_reader = &argv[2];

    /* The keyboard's data directory (settings.json, selections.json), as the
     * engine finds it. */
    const char *data_env = g_getenv ("BYAKARON_DATA_DIR");
    if (data_env != NULL && *data_env)
        g_data = g_strdup (data_env);
    else {
        const char *xdg = g_getenv ("XDG_DATA_HOME");
        g_data = (xdg != NULL && *xdg)
            ? g_build_filename (xdg, "byakaron", NULL)
            : g_build_filename (g_get_home_dir (), ".local", "share", "byakaron", NULL);
    }

    GError *err = NULL;
    g_bus = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, &err);
    if (g_bus == NULL) {
        printf ("  FAIL %s no session bus: %s\n", g_label, err->message);
        return 1;
    }
    GVariant *r = call ("/org/gnome/Mutter/RemoteDesktop", RD, "CreateSession", NULL);
    g_variant_get (r, "(o)", &g_session);
    g_variant_unref (r);
    session_call ("Start", NULL);

    if (!warm_up (60.0)) {
        printf ("  FAIL %s never received keys through IBus (60 s)\n", g_label);
        fflush (stdout);
        return 1;
    }

    t ("ami bangla + space", "আমি বাংলা ", act_ami_bangla);
    t ("bhalO. (Shift)", "ভালো। ", act_bhalo);
    t ("2026 numerals", "২০২৬ ", act_2026);

    /* Only Avro's first candidate for "ami" is pinned (as in ime_test.c); the
     * others are checked against each other, so a dictionary change does not
     * break them. */
    char *second = run (act_pick2);
    const size_t n = strlen (second);
    report ("pick candidate 2", second,
            n > 0 && strcmp (second, "আমি") != 0 && second[n - 1] != ' ',
            "a word other than আমি");
    /* Remember my choices: the pick is learned, so the next "ami" opens on it
     * and Space takes it. */
    char *remembered = g_strdup_printf ("%s %s ", second, second);
    t ("Remember my choices", remembered, act_remember);
    g_free (remembered);
    g_free (second);

    t ("click commits once", "আমি", act_click_commit);
    char *third = run (act_pick3);
    t ("Down Down Enter", third, act_down_down_enter);
    g_free (third);

    if (g_strcmp0 (g_getenv ("BYK_SPELL_DB_PRESENT"), "1") == 0) {
        /* The composer lists Avro's dictionary words first, so সোনার is already
         * first for "sonar" (corrections are only added when Avro has none). */
        t ("sonar + Space (dictionary word first)", "সোনার ", act_sonar);
    }
    if (g_strcmp0 (g_getenv ("BYK_SETTINGS_TEST"), "1") == 0) {
        setting ("bangla_digits", FALSE);
        t ("Bangla digits off: 2026", "2026 ", act_2026);
        setting ("bangla_digits", TRUE);
        t ("Bangla digits on: 2026", "২০২৬ ", act_2026);
    }

    session_call ("Stop", NULL);
    g_free (g_session);
    g_free (g_data);
    g_object_unref (g_bus);
    return g_fails ? 1 : 0;
}
