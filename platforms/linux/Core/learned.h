/*
 * Learned words: how often the user picked each suggestion.
 *
 * Every candidate the user chooses (number key, arrows + Enter, a click in
 * the panel) is counted, and the composer ranks often-picked words higher in
 * later lists. The first entry stays where it is, so Space and 1 keep meaning
 * "the word as typed".
 *
 * Stored as "count<TAB>word" lines in $XDG_DATA_HOME/byakaron/learned-words.txt
 * (normally ~/.local/share/byakaron/), written atomically on each pick, at
 * most BYK_LEARNED_MAX words (the least used are dropped). The GTK app can
 * clear it; the keyboard notices the same way it notices the personal
 * dictionary: by re-reading the small file at most once a second, comparing
 * contents. BYAKARON_LEARNED overrides the path (tests).
 */
#ifndef BYAKARON_LINUX_LEARNED_H
#define BYAKARON_LINUX_LEARNED_H

#include <glib.h>

G_BEGIN_DECLS

#define BYK_LEARNED_MAX 2000

typedef struct _BykLearned BykLearned;

/* Loads the file if it exists; a missing file means nothing learned yet. */
BykLearned *byk_learned_new (void);
void byk_learned_free (BykLearned *self);

const gchar *byk_learned_path (BykLearned *self);

/* Times `word` was picked; 0 if never. */
guint byk_learned_count (BykLearned *self, const gchar *word);

/* Number of different words learned. */
guint byk_learned_size (BykLearned *self);

/* Count one pick of `word` and save. A failed save is ignored: learning is a
 * nicety and must never get in the way of typing. */
void byk_learned_pick (BykLearned *self, const gchar *word);

/* Forget everything and save an empty file. */
gboolean byk_learned_clear (BykLearned *self, GError **error);

/* Re-read the file if another process changed it (at most once a second).
 * Returns TRUE if the counts changed. */
gboolean byk_learned_reload_if_changed (BykLearned *self);

G_END_DECLS

#endif /* BYAKARON_LINUX_LEARNED_H */
