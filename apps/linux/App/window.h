/*
 * The application window: the spelling editor, with its controls in the
 * header bar as on macOS and Windows, and the primary menu. Setup, Typing and
 * Layout are in the Preferences window it owns. Owner of the engine handles
 * the pages borrow.
 */
#ifndef BYAKARON_LINUX_APP_WINDOW_H
#define BYAKARON_LINUX_APP_WINDOW_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_WINDOW (byk_window_get_type ())
G_DECLARE_FINAL_TYPE (BykWindow, byk_window, BYK, WINDOW, GtkApplicationWindow)

GtkWidget *byk_window_new (GtkApplication *app);

/*
 * NULL or "spelling" raises this window; "setup", "typing" ("settings"),
 * "candidates", "dictionary", "layout" or "updates" opens Preferences on that
 * page, and "" on the page it was on.
 * Used by the main menu and by `byakaron --page=`.
 */
void byk_window_show_page (BykWindow *self, const gchar *name);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_WINDOW_H */
