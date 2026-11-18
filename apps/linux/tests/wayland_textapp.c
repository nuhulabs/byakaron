/*
 * wayland_textapp <outfile>: a fullscreen GtkTextView that mirrors its text
 * into <outfile> on every change. The Wayland e2e (`zig build
 * linux-wayland-e2e`, src/build/linux.zig) types into it through GNOME Shell
 * and reads <outfile> back.
 *
 * One source, two binaries: compiled against gtk+-3.0 it is
 * byakaron-wayland-textapp-gtk3, against gtk4 byakaron-wayland-textapp-gtk4.
 *
 * Prints "[app] GTK<n> display=<GdkDisplay type>" once the window is up; the
 * e2e waits for that line before it types.
 */
#include <gtk/gtk.h>
#include <locale.h>
#include <stdio.h>

static const char *g_out = NULL;

static void
on_changed (GtkTextBuffer *buf, gpointer data)
{
    (void) data;
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds (buf, &start, &end);
    char *text = gtk_text_buffer_get_text (buf, &start, &end, FALSE);
    GError *err = NULL;
    /* Written whole and renamed into place, so a reader never sees half a file. */
    if (!g_file_set_contents (g_out, text, -1, &err)) {
        fprintf (stderr, "[app] cannot write %s: %s\n", g_out, err->message);
        g_error_free (err);
    }
    g_free (text);
}

static void
report (void)
{
    GdkDisplay *display = gdk_display_get_default ();
    printf ("[app] GTK%d display=%s\n", GTK_MAJOR_VERSION,
            display != NULL ? G_OBJECT_TYPE_NAME (display) : "(none)");
    fflush (stdout);
}

#if GTK_MAJOR_VERSION >= 4

static void
on_activate (GtkApplication *app, gpointer data)
{
    (void) data;
    GtkWidget *window = gtk_application_window_new (app);
    GtkWidget *view = gtk_text_view_new ();
    gtk_window_set_child (GTK_WINDOW (window), view);
    g_signal_connect (gtk_text_view_get_buffer (GTK_TEXT_VIEW (view)), "changed",
                      G_CALLBACK (on_changed), NULL);
    gtk_window_present (GTK_WINDOW (window));
    gtk_window_fullscreen (GTK_WINDOW (window));
    gtk_widget_grab_focus (view);
    report ();
}

int
main (int argc, char *argv[])
{
    setlocale (LC_ALL, "");
    if (argc != 2) {
        fprintf (stderr, "usage: %s <outfile>\n", argv[0]);
        return 2;
    }
    g_out = argv[1];
    /* No application id: never registers a bus name, never "already running". */
    GtkApplication *app = gtk_application_new (NULL, G_APPLICATION_NON_UNIQUE);
    g_signal_connect (app, "activate", G_CALLBACK (on_activate), NULL);
    /* GApplication must not see <outfile> as a file to open. */
    const int status = g_application_run (G_APPLICATION (app), 0, NULL);
    g_object_unref (app);
    return status;
}

#else /* GTK 3 */

int
main (int argc, char *argv[])
{
    gtk_init (&argc, &argv);
    if (argc != 2) {
        fprintf (stderr, "usage: %s <outfile>\n", argv[0]);
        return 2;
    }
    g_out = argv[1];
    GtkWidget *window = gtk_window_new (GTK_WINDOW_TOPLEVEL);
    GtkWidget *view = gtk_text_view_new ();
    gtk_container_add (GTK_CONTAINER (window), view);
    g_signal_connect (gtk_text_view_get_buffer (GTK_TEXT_VIEW (view)), "changed",
                      G_CALLBACK (on_changed), NULL);
    g_signal_connect (window, "destroy", G_CALLBACK (gtk_main_quit), NULL);
    gtk_widget_show_all (window);
    gtk_window_fullscreen (GTK_WINDOW (window));
    gtk_widget_grab_focus (view);
    report ();
    gtk_main ();
    return 0;
}

#endif
