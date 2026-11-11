#include "updates.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <glib/gstdio.h>

#include "app.h"
#include "prefs.h"
#include "update.h"

enum {
    BYK_UPDATE_RESPONSE_UPDATE = 1,
    BYK_UPDATE_RESPONSE_LATER = 2,
    BYK_UPDATE_RESPONSE_RESTART = 3,
};

#define BYK_UPDATE_EVERY (24 * 60 * 60) /* seconds between automatic checks */

typedef struct {
    GtkWidget *bar;
    GtkWidget *label;
    GtkWidget *update, *later, *restart;   /* the bar's buttons */
    GCancellable *cancel;
    gboolean busy;
    gboolean gone;        /* the window is closing: no more UI */
    gboolean asked;
    gchar *base;
    gchar *installed;     /* dpkg version, e.g. 1:0.1.5 */
    gchar *tag;           /* v27.0.0 */
    gchar *version;       /* 1:27.0.0 */
    gchar *deb_name;      /* byakaron_amd64.deb */
    gchar *dir;           /* the download's temporary folder */
} BykUpdates;

static void
byk_updates_clear_download (BykUpdates *u)
{
    if (u->dir == NULL)
        return;
    gchar *deb = g_build_filename (u->dir, u->deb_name, NULL);
    gchar *sums = g_build_filename (u->dir, "SHA256SUMS", NULL);
    g_unlink (deb);
    g_unlink (sums);
    g_rmdir (u->dir);
    g_free (deb);
    g_free (sums);
    g_clear_pointer (&u->dir, g_free);
}

static void
byk_updates_free (gpointer data)
{
    BykUpdates *u = data;
    byk_updates_clear_download (u);
    g_clear_object (&u->cancel);
    g_free (u->base);
    g_free (u->installed);
    g_free (u->tag);
    g_free (u->version);
    g_free (u->deb_name);
    g_free (u);
}

static BykUpdates *
byk_updates_get (GtkWidget *bar)
{
    return g_object_get_data (G_OBJECT (bar), "byk-updates");
}

/* Say `text` with these buttons; NULL text hides the bar. */
static void
byk_updates_show (BykUpdates *u, GtkMessageType type, const gchar *text,
                  gboolean update, gboolean later, gboolean restart)
{
    GtkInfoBar *bar = GTK_INFO_BAR (u->bar);

    if (u->gone)
        return;
    if (text == NULL) {
        gtk_widget_hide (u->bar);
        return;
    }
    gtk_info_bar_set_message_type (bar, type);
    gtk_label_set_text (GTK_LABEL (u->label), text);
    /* GTK3 has no gtk_info_bar_set_response_visible. */
    gtk_widget_set_visible (u->update, update);
    gtk_widget_set_visible (u->later, later);
    gtk_widget_set_visible (u->restart, restart);
    gtk_widget_set_sensitive (u->update, !u->busy);
    gtk_widget_show (u->bar);
}

static void
byk_updates_done (BykUpdates *u)
{
    u->busy = FALSE;
    g_object_unref (u->bar); /* taken when the step started */
}

/* Run argv; on_done gets its exit status (-1: it did not run) and output. */
typedef void (*BykStepDone) (BykUpdates *u, gint status, const gchar *output);

typedef struct {
    BykUpdates *u;
    BykStepDone done;
} BykStep;

static void
on_step_finished (GObject *source, GAsyncResult *result, gpointer user_data)
{
    BykStep *step = user_data;
    GSubprocess *proc = G_SUBPROCESS (source);
    gchar *out = NULL;
    gint status = -1;

    if (g_subprocess_communicate_utf8_finish (proc, result, &out, NULL, NULL) &&
        g_subprocess_get_if_exited (proc))
        status = g_subprocess_get_exit_status (proc);
    if (!step->u->gone)
        step->done (step->u, status, out != NULL ? out : "");
    else
        byk_updates_done (step->u);
    g_free (out);
    g_free (step);
}

static gboolean
byk_updates_run (BykUpdates *u, const gchar *const *argv, BykStepDone done)
{
    GError *error = NULL;
    GSubprocess *proc = g_subprocess_newv (argv,
                                           G_SUBPROCESS_FLAGS_STDOUT_PIPE |
                                           G_SUBPROCESS_FLAGS_STDERR_MERGE,
                                           &error);
    if (proc == NULL) {
        g_message ("byakaron: could not run %s: %s", argv[0], error->message);
        g_error_free (error);
        return FALSE;
    }
    BykStep *step = g_new0 (BykStep, 1);
    step->u = u;
    step->done = done;
    g_subprocess_communicate_utf8_async (proc, NULL, u->cancel, on_step_finished, step);
    g_object_unref (proc);
    return TRUE;
}

/* The last non-empty line of `output`, for a short error message. */
static gchar *
byk_last_line (const gchar *output)
{
    gchar **lines = g_strsplit (output, "\n", -1);
    gchar *last = NULL;
    for (gchar **l = lines; *l != NULL; l++) {
        gchar *t = g_strstrip (*l);
        if (*t != '\0') {
            g_free (last);
            last = g_strdup (t);
        }
    }
    g_strfreev (lines);
    return last != NULL ? last : g_strdup ("no output");
}

/* ── 4. installed ────────────────────────────────────────────────────────── */

static void
on_installed (BykUpdates *u, gint status, const gchar *output)
{
    gchar *now = byk_update_installed_version ();
    gchar *shown = byk_update_shown_version (u->version);
    gchar *text;

    byk_updates_clear_download (u);
    u->busy = FALSE;
    if (status == 0 && now != NULL && g_strcmp0 (now, u->version) == 0) {
        text = g_strdup_printf ("Byakaron %s is installed and the keyboard has restarted. "
                                "Restart the app to finish.", shown);
        byk_updates_show (u, GTK_MESSAGE_INFO, text, FALSE, FALSE, TRUE);
        g_free (u->installed);
        u->installed = g_strdup (now);
    } else if (status == 126 || status == 127) {
        /* pkexec: the password prompt was dismissed, or not allowed. */
        text = g_strdup ("The update was cancelled. Nothing was changed.");
        byk_updates_show (u, GTK_MESSAGE_INFO, text, TRUE, TRUE, FALSE);
    } else {
        gchar *why = byk_last_line (output);
        text = g_strdup_printf ("The update did not install: %s", why);
        byk_updates_show (u, GTK_MESSAGE_WARNING, text, TRUE, TRUE, FALSE);
        g_free (why);
    }
    g_free (text);
    g_free (shown);
    g_free (now);
    byk_updates_done (u); /* may free u: last */
}

/* ── 3. checked: install it ──────────────────────────────────────────────── */

static void
byk_updates_install (BykUpdates *u)
{
    gchar *deb = g_build_filename (u->dir, u->deb_name, NULL);
    gchar *apt = g_find_program_in_path ("apt-get");
    gchar *pkexec = g_find_program_in_path ("pkexec");
    gboolean root = geteuid () == 0;
    gboolean started = FALSE;

    /* pkexec's prompt names the program, so it is apt-get itself (not env):
     * "Authentication is needed to run /usr/bin/apt-get as the super user".
     * The lock timeout waits out Software Updater instead of failing. */
    if (apt != NULL && (root || pkexec != NULL)) {
        const gchar *as_root[] = { apt, "-o", "DPkg::Lock::Timeout=120",
                                   "install", "-y", deb, NULL };
        const gchar *with_prompt[] = { pkexec, apt, "-o", "DPkg::Lock::Timeout=120",
                                       "install", "-y", deb, NULL };
        started = byk_updates_run (u, root ? as_root : with_prompt, on_installed);
    }
    if (started) {
        byk_updates_show (u, GTK_MESSAGE_INFO,
                          "Installing… enter your password if asked.",
                          FALSE, FALSE, FALSE);
    } else {
        gchar *text = g_strdup_printf ("This system cannot install it from here. "
                                       "In a terminal, run: %s", BYK_INSTALL_COMMAND);
        u->busy = FALSE;
        byk_updates_clear_download (u);
        byk_updates_show (u, GTK_MESSAGE_INFO, text, FALSE, TRUE, FALSE);
        g_free (text);
        byk_updates_done (u);
    }
    g_free (deb);
    g_free (apt);
    g_free (pkexec);
}

static gchar *
byk_file_sha256 (const gchar *path)
{
    GChecksum *sum = g_checksum_new (G_CHECKSUM_SHA256);
    FILE *f = fopen (path, "rb");
    gchar *hex = NULL;

    if (f != NULL) {
        guchar buf[64 * 1024];
        size_t n;
        while ((n = fread (buf, 1, sizeof buf, f)) > 0)
            g_checksum_update (sum, buf, n);
        if (!ferror (f))
            hex = g_strdup (g_checksum_get_string (sum));
        fclose (f);
    }
    g_checksum_free (sum);
    return hex;
}

static void
verify_in_thread (GTask *task, gpointer source, gpointer task_data, GCancellable *cancel)
{
    BykUpdates *u = task_data;
    gchar *sums_path = g_build_filename (u->dir, "SHA256SUMS", NULL);
    gchar *deb_path = g_build_filename (u->dir, u->deb_name, NULL);
    gchar *sums = NULL;
    gchar *want = NULL, *got = NULL;
    (void) source;
    (void) cancel;

    if (g_file_get_contents (sums_path, &sums, NULL, NULL))
        want = byk_update_sum_for (sums, u->deb_name);
    if (want != NULL)
        got = byk_file_sha256 (deb_path);
    g_task_return_boolean (task, want != NULL && g_strcmp0 (want, got) == 0);
    g_free (sums);
    g_free (want);
    g_free (got);
    g_free (sums_path);
    g_free (deb_path);
}

static void
on_verified (GObject *source, GAsyncResult *result, gpointer user_data)
{
    BykUpdates *u = user_data;
    gboolean ok = g_task_propagate_boolean (G_TASK (result), NULL);
    (void) source;

    if (u->gone) {
        byk_updates_done (u);
        return;
    }
    if (ok) {
        byk_updates_install (u); /* finishes the step */
        return;
    }
    byk_updates_clear_download (u);
    u->busy = FALSE;
    byk_updates_show (u, GTK_MESSAGE_WARNING,
                      "The download was damaged, so it was not installed. Try again.",
                      TRUE, TRUE, FALSE);
    byk_updates_done (u);
}

/* ── 2. downloaded: check it ─────────────────────────────────────────────── */

static void
on_downloaded (BykUpdates *u, gint status, const gchar *output)
{
    if (status != 0) {
        gchar *why = byk_last_line (output);
        gchar *text = g_strdup_printf ("The download did not finish (%s). Try again.", why);
        byk_updates_clear_download (u);
        u->busy = FALSE;
        byk_updates_show (u, GTK_MESSAGE_WARNING, text, TRUE, TRUE, FALSE);
        g_free (text);
        g_free (why);
        byk_updates_done (u);
        return;
    }
    byk_updates_show (u, GTK_MESSAGE_INFO, "Checking the download…", FALSE, FALSE, FALSE);
    GTask *task = g_task_new (NULL, u->cancel, on_verified, u);
    g_task_set_task_data (task, u, NULL);
    g_task_run_in_thread (task, verify_in_thread);
    g_object_unref (task);
}

static void
byk_updates_download (BykUpdates *u)
{
    gchar *deb_url, *sums_url, *deb_path, *sums_path, *text, *shown;
    GError *error = NULL;

    if (u->busy || u->tag == NULL)
        return;
    byk_updates_clear_download (u);
    u->dir = g_dir_make_tmp ("byakaron-update-XXXXXX", &error);
    if (u->dir == NULL) {
        byk_updates_show (u, GTK_MESSAGE_WARNING, error->message, TRUE, TRUE, FALSE);
        g_error_free (error);
        return;
    }
    deb_url = g_strdup_printf ("%s/releases/download/%s/%s", u->base, u->tag, u->deb_name);
    sums_url = g_strdup_printf ("%s/releases/download/%s/SHA256SUMS", u->base, u->tag);
    deb_path = g_build_filename (u->dir, u->deb_name, NULL);
    sums_path = g_build_filename (u->dir, "SHA256SUMS", NULL);
    const gchar *argv[] = { "curl", "-fsSL", "--max-time", "900",
                            "-o", deb_path, deb_url, "-o", sums_path, sums_url, NULL };

    u->busy = TRUE;
    g_object_ref (u->bar);
    if (byk_updates_run (u, argv, on_downloaded)) {
        shown = byk_update_shown_version (u->version);
        text = g_strdup_printf ("Downloading Byakaron %s (about 90 MB)…", shown);
        byk_updates_show (u, GTK_MESSAGE_INFO, text, FALSE, FALSE, FALSE);
        g_free (text);
        g_free (shown);
    } else {
        byk_updates_clear_download (u);
        byk_updates_done (u);
        byk_updates_show (u, GTK_MESSAGE_WARNING,
                          "Updating needs curl: sudo apt install curl", FALSE, TRUE, FALSE);
    }
    g_free (deb_url);
    g_free (sums_url);
    g_free (deb_path);
    g_free (sums_path);
}

/* ── 1. checked GitHub ───────────────────────────────────────────────────── */

static void
on_checked (BykUpdates *u, gint status, const gchar *output)
{
    gchar *tag = status == 0 ? byk_update_tag_from_url (g_strstrip ((gchar *) output)) : NULL;
    gchar *version = byk_update_deb_version (tag);
    gchar *mine = byk_update_shown_version (u->installed);
    GSettings *prefs = byk_prefs_try_open ();

    u->busy = FALSE;
    if (status == 0)
        byk_prefs_set_int64 (prefs, BYK_PREFS_LAST_UPDATE_CHECK,
                             g_get_real_time () / G_USEC_PER_SEC);
    g_clear_object (&prefs);

    if (version != NULL && byk_update_newer (version, u->installed)) {
        gchar *shown = byk_update_shown_version (version);
        gchar *text = g_strdup_printf ("Byakaron %s is available. You have %s.", shown, mine);
        g_free (u->tag);
        g_free (u->version);
        u->tag = g_strdup (tag);
        u->version = g_strdup (version);
        byk_updates_show (u, GTK_MESSAGE_INFO, text, TRUE, TRUE, FALSE);
        g_free (text);
        g_free (shown);
    } else if (u->asked) {
        gchar *text = status == 0
            ? g_strdup_printf ("Byakaron %s is the newest version.", mine)
            : g_strdup ("Could not reach github.com to check. Try again later.");
        byk_updates_show (u, status == 0 ? GTK_MESSAGE_INFO : GTK_MESSAGE_WARNING,
                          text, FALSE, TRUE, FALSE);
        g_free (text);
    }
    g_free (mine);
    g_free (version);
    g_free (tag);
    byk_updates_done (u);
}

void
byk_updates_check (GtkWidget *bar, gboolean asked)
{
    BykUpdates *u = byk_updates_get (bar);
    gchar *latest;

    g_return_if_fail (u != NULL);
    if (u->busy)
        return;
    u->asked = asked;

    g_free (u->installed);
    u->installed = byk_update_installed_version ();
    if (u->installed == NULL) {
        if (asked)
            byk_updates_show (u, GTK_MESSAGE_INFO,
                              "This Byakaron was not installed from a .deb, so it cannot update itself.",
                              FALSE, TRUE, FALSE);
        return;
    }
    if (u->deb_name == NULL)
        u->deb_name = byk_update_deb_name ();
    if (u->deb_name == NULL)
        return;

    /* /releases/latest redirects to /releases/tag/<newest normal release>;
     * the redirect itself is the answer, so it is not followed. */
    latest = g_strdup_printf ("%s/releases/latest", u->base);
    const gchar *argv[] = { "curl", "-sS", "-o", "/dev/null", "-w", "%{redirect_url}",
                            "--max-time", "20", latest, NULL };
    u->busy = TRUE;
    g_object_ref (u->bar);
    if (!byk_updates_run (u, argv, on_checked)) {
        byk_updates_done (u);
        if (asked)
            byk_updates_show (u, GTK_MESSAGE_WARNING,
                              "Checking for updates needs curl: sudo apt install curl",
                              FALSE, TRUE, FALSE);
    }
    g_free (latest);
}

void
byk_updates_check_if_due (GtkWidget *bar)
{
    GSettings *prefs = byk_prefs_try_open ();
    gboolean due = FALSE;

    /* Without the schema (a build run from zig-out) there is no switch to
     * respect, so only Check now checks. */
    if (prefs != NULL && byk_prefs_boolean (prefs, BYK_PREFS_CHECK_UPDATES, FALSE)) {
        const gint64 last = byk_prefs_int64 (prefs, BYK_PREFS_LAST_UPDATE_CHECK, 0);
        const gint64 now = g_get_real_time () / G_USEC_PER_SEC;
        due = now - last >= BYK_UPDATE_EVERY || now < last;
    }
    g_clear_object (&prefs);
    if (due)
        byk_updates_check (bar, FALSE);
}

/* ── the bar ─────────────────────────────────────────────────────────────── */

static void
byk_updates_restart (void)
{
    gchar *self = g_file_read_link ("/proc/self/exe", NULL);
    /* dpkg has just replaced the file: the link now ends in " (deleted)". */
    if (self != NULL && g_str_has_suffix (self, " (deleted)"))
        self[strlen (self) - strlen (" (deleted)")] = '\0';
    if (self != NULL && !g_file_test (self, G_FILE_TEST_IS_EXECUTABLE))
        g_clear_pointer (&self, g_free);
    const gchar *argv[] = { "/bin/sh", "-c", "sleep 1; exec \"$0\"",
                            self != NULL ? self : "byakaron", NULL };

    /* After this process has quit, so the new one is not handed to it as a
     * second instance. */
    g_spawn_async (NULL, (gchar **) argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, NULL);
    g_free (self);
    g_application_quit (g_application_get_default ());
}

static void
on_bar_response (GtkInfoBar *bar, gint response, gpointer user_data)
{
    BykUpdates *u = user_data;
    (void) bar;

    switch (response) {
    case BYK_UPDATE_RESPONSE_UPDATE:
        byk_updates_download (u);
        break;
    case BYK_UPDATE_RESPONSE_RESTART:
        byk_updates_restart ();
        break;
    default:
        if (!u->busy)
            gtk_widget_hide (u->bar);
        break;
    }
}

static void
on_bar_destroy (GtkWidget *bar, gpointer user_data)
{
    BykUpdates *u = user_data;
    (void) bar;
    u->gone = TRUE;
    g_cancellable_cancel (u->cancel);
}

GtkWidget *
byk_updates_bar_new (void)
{
    BykUpdates *u = g_new0 (BykUpdates, 1);
    GtkWidget *bar = gtk_info_bar_new ();

    u->bar = bar;
    u->cancel = g_cancellable_new ();
    u->base = byk_update_base ();

    u->label = gtk_label_new (NULL);
    gtk_label_set_line_wrap (GTK_LABEL (u->label), TRUE);
    gtk_label_set_selectable (GTK_LABEL (u->label), TRUE);
    gtk_label_set_xalign (GTK_LABEL (u->label), 0.0f);
    gtk_widget_set_can_focus (u->label, FALSE);
    gtk_container_add (GTK_CONTAINER (gtk_info_bar_get_content_area (GTK_INFO_BAR (bar))),
                       u->label);
    u->update = gtk_info_bar_add_button (GTK_INFO_BAR (bar), "_Update", BYK_UPDATE_RESPONSE_UPDATE);
    u->later = gtk_info_bar_add_button (GTK_INFO_BAR (bar), "_Later", BYK_UPDATE_RESPONSE_LATER);
    u->restart = gtk_info_bar_add_button (GTK_INFO_BAR (bar), "_Restart", BYK_UPDATE_RESPONSE_RESTART);

    g_object_set_data_full (G_OBJECT (bar), "byk-updates", u, byk_updates_free);
    g_signal_connect (bar, "response", G_CALLBACK (on_bar_response), u);
    g_signal_connect (bar, "destroy", G_CALLBACK (on_bar_destroy), u);

    gtk_widget_show_all (bar);
    gtk_widget_set_no_show_all (bar, TRUE);
    gtk_widget_hide (bar);
    return bar;
}
