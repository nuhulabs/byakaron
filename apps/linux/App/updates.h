/*
 * The "Byakaron X is available" bar at the top of the window, and the update
 * behind its Update button: download the .deb from Byakaron-Assets, check it
 * against that release's SHA256SUMS, install it with apt through pkexec (the
 * system password prompt). The package's postinst restarts IBus, so the
 * keyboard is new at once; the app asks to be restarted.
 *
 * Checks happen once a day at most, only while "Check for updates" is on
 * (GSettings check-updates), and only for a Byakaron installed from a .deb.
 * A check is one request to github.com, nothing else is sent.
 */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* The bar, hidden until there is something to say. */
GtkWidget *byk_updates_bar_new (void);

/* Check now. `asked`: someone pressed Check now, so also say when there is
 * nothing newer, or why it cannot check. */
void byk_updates_check (GtkWidget *bar, gboolean asked);

/* Check when updates are on and the last check is a day old. */
void byk_updates_check_if_due (GtkWidget *bar);

G_END_DECLS
