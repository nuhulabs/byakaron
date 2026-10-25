/*
 * Type Bangla into a GtkEntry through the IBus GTK IM module.
 *
 * The engine is display-agnostic. This is the client half: a realised GtkEntry
 * and gtk_im_context_filter_key with GTK_IM_MODULE=ibus. Commits land in the
 * entry the way they would for a user typing into any GTK4 field.
 *
 * Nested mutter is a virtual seat. GTK4's IBus module often cannot eat those
 * synthetic keys (the engine never sees them; the entry gets latin). The
 * session X11 / Xvfb path is the one that actually proves IM-module typing.
 * text-input-v3 on nested mutter is covered by wayland_probe.
 *
 * Built by `zig build linux-wayland`; run by `zig build linux-ci`.
 */
#include <gtk/gtk.h>
#include <locale.h>
#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static GtkWidget *g_entry = NULL;
static GtkIMContext *g_im = NULL;
static GdkSurface *g_surface = NULL;
static GdkDevice *g_keyboard = NULL;
static GdkDisplay *g_display = NULL;

static void
pump (void)
{
    const gint64 quiet_period = 40 * 1000;
    const gint64 deadline = g_get_monotonic_time () + 2 * G_TIME_SPAN_SECOND;
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
on_commit (GtkIMContext *im, const char *str, gpointer data)
{
    (void) im;
    GtkEditable *e = GTK_EDITABLE (data);
    int pos = gtk_editable_get_position (e);
    gtk_editable_insert_text (e, str, -1, &pos);
    gtk_editable_set_position (e, pos);
}

static guint
keycode_for_keyval (guint keyval)
{
    GdkKeymapKey *keys = NULL;
    int n = 0;
    if (!gdk_display_map_keyval (g_display, keyval, &keys, &n) || n <= 0)
        return 0;
    const guint code = keys[0].keycode;
    g_free (keys);
    return code;
}

static void
send_key (guint keyval)
{
    const guint code = keycode_for_keyval (keyval);
    if (code == 0) {
        fprintf (stderr, "FAIL: no keycode for keyval 0x%x\n", keyval);
        g_failures++;
        return;
    }
    gtk_im_context_filter_key (g_im, TRUE, g_surface, g_keyboard,
                               GDK_CURRENT_TIME, code, 0, 0);
    gtk_im_context_filter_key (g_im, FALSE, g_surface, g_keyboard,
                               GDK_CURRENT_TIME, code, 0, 0);
    pump ();
}

static void
check (const char *what, const char *got, const char *want)
{
    const int ok = g_strcmp0 (got ? got : "", want) == 0;
    printf ("  %-4s %-34s -> %s\n", ok ? "ok" : "FAIL", what, got ? got : "(none)");
    if (!ok) {
        printf ("       expected: %s\n", want);
        g_failures++;
    }
}

static void
on_activate (GtkApplication *app, gpointer user_data)
{
    (void) user_data;

    g_display = gdk_display_get_default ();
    if (g_display == NULL) {
        fprintf (stderr, "FAIL: no GdkDisplay\n");
        g_failures++;
        g_application_quit (G_APPLICATION (app));
        return;
    }

    const char *type = G_OBJECT_TYPE_NAME (g_display);
    const char *backend = (type && strstr (type, "Wayland")) ? "wayland"
                         : (type && strstr (type, "X11"))     ? "x11"
                         : type ? type : "(unknown)";
    printf ("backend:        %s\n", backend);
    printf ("display type:    %s\n", type ? type : "(null)");

    GtkWidget *window = gtk_application_window_new (app);
    g_entry = gtk_entry_new ();
    gtk_window_set_child (GTK_WINDOW (window), g_entry);
    gtk_window_set_default_size (GTK_WINDOW (window), 400, 80);
    gtk_window_present (GTK_WINDOW (window));
    pump ();

    if (!gtk_widget_get_realized (g_entry)) {
        fprintf (stderr, "FAIL: GtkEntry was not realised\n");
        g_failures++;
        g_application_quit (G_APPLICATION (app));
        return;
    }

    GtkNative *native = gtk_widget_get_native (g_entry);
    g_surface = native ? gtk_native_get_surface (native) : NULL;
    GdkSeat *seat = gdk_display_get_default_seat (g_display);
    g_keyboard = seat ? gdk_seat_get_keyboard (seat) : NULL;

    printf ("entry realised:  yes\n");
    printf ("keyboard device: %s\n", g_keyboard ? "yes" : "no");

    if (g_surface == NULL || g_keyboard == NULL) {
        fprintf (stderr, "FAIL: no GdkSurface or keyboard seat — cannot inject keys\n");
        g_failures++;
        g_application_quit (G_APPLICATION (app));
        return;
    }

    g_im = gtk_im_multicontext_new ();
    gtk_im_multicontext_set_context_id (GTK_IM_MULTICONTEXT (g_im), "ibus");
    gtk_im_context_set_client_widget (g_im, g_entry);
    gtk_im_context_focus_in (g_im);
    g_signal_connect (g_im, "commit", G_CALLBACK (on_commit), g_entry);

    const char *im_id = gtk_im_multicontext_get_context_id (GTK_IM_MULTICONTEXT (g_im));
    printf ("im context id:   %s\n", im_id && *im_id ? im_id : "(default)");
    printf ("im context type: %s\n", G_OBJECT_TYPE_NAME (g_im));

    puts ("typing (GtkEntry via IBus IM module):");
    send_key (GDK_KEY_a);
    send_key (GDK_KEY_m);
    send_key (GDK_KEY_i);
    send_key (GDK_KEY_space);

    const char *text = gtk_editable_get_text (GTK_EDITABLE (g_entry));
    check ("ami + space", text, "আমি ");

    g_object_unref (g_im);
    g_im = NULL;
    g_application_quit (G_APPLICATION (app));
}

int
main (int argc, char *argv[])
{
    setlocale (LC_ALL, "");

    GtkApplication *app = gtk_application_new ("dev.nuhu.labs.Byakaron.WaylandType",
                                               G_APPLICATION_NON_UNIQUE);
    g_signal_connect (app, "activate", G_CALLBACK (on_activate), NULL);
    const int status = g_application_run (G_APPLICATION (app), argc, argv);
    g_object_unref (app);

    if (g_failures)
        return 1;
    return status;
}
