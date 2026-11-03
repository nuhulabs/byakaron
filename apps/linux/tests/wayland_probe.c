/*
 * Display-backend probe for the GTK4 client stack the engine talks through.
 *
 * The engine itself never opens a display — it only speaks IBus D-Bus. What
 * this prints is which *client* path a GTK4 app on this session would use to
 * reach that daemon: the X11 IM module, the Wayland text-input-v3 context, or
 * GTK_IM_MODULE=ibus (which is D-Bus on either backend).
 *
 * Built by `zig build linux-wayland`; run by `zig build linux-ci`.
 */
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *
display_backend (GdkDisplay *display)
{
    const char *type = G_OBJECT_TYPE_NAME (display);

    /* GTK4's backend types are GdkX11Display and GdkWaylandDisplay. Matching
     * on the type name rather than compiling against gdkx.h / gdkwayland.h
     * keeps this file buildable when only one backend is present. */
    if (type != NULL && strstr (type, "Wayland") != NULL)
        return "wayland";
    if (type != NULL && strstr (type, "X11") != NULL)
        return "x11";
    return type != NULL ? type : "(unknown)";
}

static void
on_activate (GtkApplication *app, gpointer user_data)
{
    (void) user_data;

    GdkDisplay *display = gdk_display_get_default ();
    if (display == NULL) {
        fprintf (stderr, "FAIL: no GdkDisplay\n");
        g_application_quit (G_APPLICATION (app));
        return;
    }

    const char *backend = display_backend (display);
    const char *im_module = g_getenv ("GTK_IM_MODULE");
    GtkIMContext *im = gtk_im_multicontext_new ();
    const char *im_id = gtk_im_multicontext_get_context_id (GTK_IM_MULTICONTEXT (im));

    /* A realised widget is what actually owns an IM context in a real app.
     * Creating one proves the backend can map a window, which is the step a
     * headless compositor sometimes cannot take. */
    GtkWidget *window = gtk_application_window_new (app);
    GtkWidget *entry = gtk_entry_new ();
    gtk_window_set_child (GTK_WINDOW (window), entry);
    gtk_window_set_default_size (GTK_WINDOW (window), 320, 80);
    gtk_window_present (GTK_WINDOW (window));

    printf ("backend:        %s\n", backend);
    printf ("display type:    %s\n", G_OBJECT_TYPE_NAME (display));
    printf ("GTK_IM_MODULE:   %s\n", im_module && *im_module ? im_module : "(unset)");
    printf ("im context id:   %s\n", im_id && *im_id ? im_id : "(default)");
    printf ("im context type: %s\n", G_OBJECT_TYPE_NAME (im));
    printf ("entry realised:  %s\n", gtk_widget_get_realized (entry) ? "yes" : "no");

    g_object_unref (im);

    /* Print and quit: this is a probe, not a window the user interacts with. */
    g_application_quit (G_APPLICATION (app));
}

int
main (int argc, char *argv[])
{
    GtkApplication *app = gtk_application_new ("dev.nuhu.labs.Byakaron.WaylandProbe",
                                               G_APPLICATION_NON_UNIQUE);
    g_signal_connect (app, "activate", G_CALLBACK (on_activate), NULL);
    const int status = g_application_run (G_APPLICATION (app), argc, argv);
    g_object_unref (app);
    return status;
}
