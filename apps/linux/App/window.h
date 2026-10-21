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

/*
 * Show Spelling, Layout, or Setup. Unknown names fall back to Spelling.
 * Used by the hamburger menu and by `byakaron --page=`.
 */
void byk_window_show_page (BykWindow *self, const gchar *name);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_WINDOW_H */
