/*
 * The application window: a GtkStack over Spelling, Layout, and Setup, with
 * those pages in the header-bar menu. Owner of the engine handles the pages
 * borrow.
 */
#ifndef BYAKARON_LINUX_APP_WINDOW_H
#define BYAKARON_LINUX_APP_WINDOW_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_WINDOW (byk_window_get_type ())
G_DECLARE_FINAL_TYPE (BykWindow, byk_window, BYK, WINDOW, GtkApplicationWindow)

GtkWidget *byk_window_new (GtkApplication *app);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_WINDOW_H */
