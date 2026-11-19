/*
 * Settings pages: how the keyboard behaves, one manifest section per page.
 *
 * The settings every Byakaron keyboard shares, saved to settings.json through
 * the app's composer (Core/composer.h); the IBus engine and the Fcitx5 addon
 * pick them up at their next word, with no restart. Preferences builds one
 * page per section ("typing", "candidates", "updates"), the tabs macOS and
 * Windows have. The Linux-only Qt click fix stays in GSettings (Core/prefs.h)
 * and goes on the Typing page; Check Now goes on the Updates page.
 */
#ifndef BYAKARON_LINUX_APP_SETTINGS_H
#define BYAKARON_LINUX_APP_SETTINGS_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_SETTINGS_PAGE (byk_settings_page_get_type ())
G_DECLARE_FINAL_TYPE (BykSettingsPage, byk_settings_page, BYK, SETTINGS_PAGE, GtkBox)

/* `section_id` is a ByakaronSettingsSection id; the page shows its Linux fields. */
GtkWidget *byk_settings_page_new (BykEngines *engines, const gchar *section_id);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_SETTINGS_H */
