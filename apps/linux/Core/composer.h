/*
 * Linux glue over libbyakaron's Composer (src/Composer.zig, byakaron.h).
 *
 * The keyboard itself — the latin buffer, Avro's candidates, paging, the
 * highlight, learning, the personal dictionary, spelling corrections and the
 * shared settings — lives in Zig, identical on every platform. What is left
 * here is what only Linux knows: where the data directory and Byakaron.db are,
 * how X11 keysyms (IBus, GDK and Fcitx5 all speak them) map to composer keys,
 * the one-time move of the old GSettings keys into settings.json, and small
 * GLib-friendly readers for the JSON the ABI returns.
 *
 * Shared by Keyboard/ (IBus), Fcitx5/ and App/ (the GTK app).
 */
#ifndef BYAKARON_LINUX_COMPOSER_H
#define BYAKARON_LINUX_COMPOSER_H

#include <glib.h>

#include "byakaron.h"

G_BEGIN_DECLS

/*
 * Where settings.json, selections.json and user-words.txt live:
 * $BYAKARON_DATA_DIR (tests), else $XDG_DATA_HOME/byakaron (normally
 * ~/.local/share/byakaron). g_free.
 */
gchar *byk_data_dir (void);

/*
 * A composer on byk_data_dir(). With `with_spell`, spelling corrections come
 * from Byakaron.db (byk_spell_locate_db) and `on_update(userdata)` fires on a
 * worker thread when they arrive: hop to the main loop, then
 * byakaron_composer_refresh and redraw. Before the first settings.json exists,
 * the old GSettings values are written into it once (see composer.c).
 * NULL if the composer could not be created.
 */
ByakaronComposer *byk_composer_open (gboolean with_spell, ByakaronUpdateFn on_update,
                                     gpointer userdata);

/*
 * Map an X11 keysym to a composer key (BYAKARON_KEY_*, and the ASCII character
 * for BYAKARON_KEY_CHAR). Keypad digits, Enter, Space, arrows and pages count
 * as their main-keyboard twins. Returns FALSE for keys that produce nothing by
 * themselves (Shift, Caps Lock, AltGr, Num Lock, …): those are not sent at
 * all, or Shift in `bhalO` would end the word before the O.
 */
gboolean byk_keysym_to_key (guint keyval, int *kind, unsigned int *ch);

/* The shared settings (src/Composer/Settings.zig), as the app edits them. */
typedef struct {
    gboolean suggestions;
    gboolean spelling_corrections;
    gboolean learn_choices;
    gboolean bangla_digits;
    gboolean newline_on_enter;
    gboolean vertical;        /* candidate_orientation */
    gint candidates_per_page; /* 3–9 */
} BykSettings;

void byk_settings_defaults (BykSettings *out);
/* Current settings; defaults for anything missing. */
void byk_settings_load (ByakaronComposer *composer, BykSettings *out);
/* Save all of them; FALSE if the composer rejected the JSON. */
gboolean byk_settings_save (ByakaronComposer *composer, const BykSettings *settings);

/* The personal dictionary, sorted. Never NULL; g_strfreev. */
gchar **byk_userdict_words (ByakaronComposer *composer);
gboolean byk_userdict_contains (ByakaronComposer *composer, const gchar *word);

/*
 * Parse a flat JSON array of strings (the ABI's word lists). NULL if it is
 * malformed or not valid UTF-8; g_strfreev.
 */
gchar **byk_parse_json_strings (const gchar *json);

G_END_DECLS

#endif /* BYAKARON_LINUX_COMPOSER_H */
