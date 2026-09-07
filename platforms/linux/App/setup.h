/*
 * "Setup" page — keyboard status, how to add it, and a typing cheat-sheet.
 *
 * Mirrors the macOS GettingStartedTab, with the two checks the Linux install
 * actually has: whether the IBus component is registered on the system, and
 * whether the user has added Byakaron to their input sources. Those are
 * separate steps here (the macOS installer does both at once), and telling
 * them apart is the difference between "run the installer" and "click + in
 * Settings".
 */
#ifndef BYAKARON_LINUX_APP_SETUP_H
#define BYAKARON_LINUX_APP_SETUP_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_SETUP_PAGE (byk_setup_page_get_type ())
G_DECLARE_FINAL_TYPE (BykSetupPage, byk_setup_page, BYK, SETUP_PAGE, AdwBin)

GtkWidget *byk_setup_page_new (void);

/* Re-read the keyboard status. Called when the page comes into view, since
 * adding an input source happens outside this app. */
void byk_setup_page_refresh (BykSetupPage *self);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_SETUP_H */
