/*
 * Settings page: how the keyboard behaves, and the personal dictionary.
 *
 * The seven settings every Byakaron keyboard shares, saved to settings.json
 * through the app's composer (Core/composer.h); the IBus engine and the Fcitx5
 * addon pick them up at their next word, with no restart. The Linux-only Qt
 * click fix stays in GSettings (Core/prefs.h). The dictionary row opens the
 * same window as the main menu.
 */
#ifndef BYAKARON_LINUX_APP_SETTINGS_H
#define BYAKARON_LINUX_APP_SETTINGS_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_SETTINGS_PAGE (byk_settings_page_get_type ())
G_DECLARE_FINAL_TYPE (BykSettingsPage, byk_settings_page, BYK, SETTINGS_PAGE, GtkBox)

/* `on_dictionary_changed` runs after words are added or removed. */
GtkWidget *byk_settings_page_new (BykEngines *engines,
                                  GCallback on_dictionary_changed, gpointer data);

/* Refresh the saved-word count, e.g. after the Spelling page added one. */
void byk_settings_page_refresh (BykSettingsPage *self);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_SETTINGS_H */
