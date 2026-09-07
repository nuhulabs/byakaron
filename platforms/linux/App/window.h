/*
 * The application window: one AdwViewStack over the four pages, and the owner
 * of the engine handles they all borrow.
 */
#ifndef BYAKARON_LINUX_APP_WINDOW_H
#define BYAKARON_LINUX_APP_WINDOW_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_WINDOW (byk_window_get_type ())
G_DECLARE_FINAL_TYPE (BykWindow, byk_window, BYK, WINDOW, AdwApplicationWindow)

GtkWidget *byk_window_new (AdwApplication *app);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_WINDOW_H */
