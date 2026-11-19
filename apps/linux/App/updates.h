/*
 * The "Byakaron X is available" bar at the top of the window, and the update
 * behind its Update button: download the package from Byakaron-Assets (the
 * .deb, or the Arch package on Arch Linux), check it against that release's
 * SHA256SUMS, install it with apt or pacman through pkexec (the system
 * password prompt). The package's postinst (.INSTALL on Arch) restarts IBus,
 * so the keyboard is new at once; the app asks to be restarted.
 *
 * Checks happen once a day at most, only while "Check for updates" is on
 * (the shared `auto_update` setting), and only for a Byakaron installed from a
 * package. A check is one request to github.com for the release list, nothing
 * else is sent; the shared core (src/Update.zig, byakaron_update_pick) picks
 * the release for the `update_channel` setting, the package manager confirms
 * it is newer.
 */
#pragma once

#include <gtk/gtk.h>

#include "byakaron.h"

G_BEGIN_DECLS

/* The bar, hidden until there is something to say. `composer` (the window's,
 * may be NULL) holds the update settings; it must outlive the bar. */
GtkWidget *byk_updates_bar_new (ByakaronComposer *composer);

/* Check now. `asked`: someone pressed Check now, so also say when there is
 * nothing newer, or why it cannot check. */
void byk_updates_check (GtkWidget *bar, gboolean asked);

/* Check when updates are on and the last check is a day old. */
void byk_updates_check_if_due (GtkWidget *bar);

G_END_DECLS
