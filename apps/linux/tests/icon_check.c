/*
 * icon_check <image> <size>...: load <image> with gdk-pixbuf at each size, the
 * way GNOME's app grid draws an app icon, and check it comes out <size> px
 * wide. Exit 0 when every size loads, 1 otherwise.
 *
 * icon_check --probe: exit 0. Proves the binary and libgdk_pixbuf-2.0 load on
 * this system, so a caller can skip (not fail) where gdk-pixbuf is missing.
 *
 * Run by `linux ci` (the source byakaron.svg) and `linux tested` (the
 * installed one), src/build/linux.zig. 0.1.8 shipped an SVG that gdk-pixbuf
 * would not load, and the app grid showed a blank tile.
 */
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int
main (int argc, char *argv[])
{
    if (argc == 2 && strcmp (argv[1], "--probe") == 0) {
        printf ("gdk-pixbuf %s\n", gdk_pixbuf_version);
        return 0;
    }
    if (argc < 3) {
        fprintf (stderr, "usage: %s <image> <size>...\n       %s --probe\n", argv[0], argv[0]);
        return 2;
    }

    int failures = 0;
    for (int i = 2; i < argc; i++) {
        char *end = NULL;
        const long size = strtol (argv[i], &end, 10);
        if (end == argv[i] || *end != '\0' || size <= 0 || size > 4096) {
            fprintf (stderr, "%s: bad size '%s'\n", argv[0], argv[i]);
            return 2;
        }
        GError *err = NULL;
        GdkPixbuf *p = gdk_pixbuf_new_from_file_at_size (argv[1], (int) size, (int) size, &err);
        if (p == NULL) {
            fprintf (stderr, "%s at %ld px: %s\n", argv[1], size, err != NULL ? err->message : "no image");
            g_clear_error (&err);
            failures++;
            continue;
        }
        const int width = gdk_pixbuf_get_width (p);
        if (width != size) {
            fprintf (stderr, "%s at %ld px: loaded %d px wide\n", argv[1], size, width);
            failures++;
        }
        g_object_unref (p);
    }
    return failures ? 1 : 0;
}
