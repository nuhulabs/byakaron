/*
 * The Preferences window: Setup, Typing, Suggestions, Dictionary, Layout and
 * Updates, as tabs in its header bar, the order and names macOS and Windows use.
 *
 * The Linux counterpart of the macOS Settings window (⌘,) and the Windows
 * Settings button: the main window is the spelling editor alone, and
 * everything about the keyboard lives here. Opened from the main menu,
 * Ctrl+comma, and `byakaron --page=setup` (the IBus panel's Preferences).
 */
#ifndef BYAKARON_LINUX_APP_PREFERENCES_H
#define BYAKARON_LINUX_APP_PREFERENCES_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_PREFERENCES (byk_preferences_get_type ())
G_DECLARE_FINAL_TYPE (BykPreferences, byk_preferences, BYK, PREFERENCES, GtkWindow)

/*
 * `engines` is borrowed and must outlive the window, which is why it is
 * transient for, and destroyed with, the main window that owns them.
 * `on_dictionary_changed` runs after words are added or removed.
 */
GtkWidget *byk_preferences_new (GtkWindow *parent, BykEngines *engines,
                                GCallback on_dictionary_changed, gpointer data);

/*
 * Present the window on `page`: "setup", "typing", "candidates", "dictionary",
 * "layout" or "updates" ("settings" is the old name for typing). NULL or ""
 * keeps the page it was on.
 */
void byk_preferences_present (BykPreferences *self, const gchar *page);

/* Re-read what other windows may have changed (keyboard status, saved words). */
void byk_preferences_refresh (BykPreferences *self);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_PREFERENCES_H */
