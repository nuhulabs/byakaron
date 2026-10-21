/*
 * Thin GLib-friendly wrapper around libbyakaron's autocomplete ABI.
 *
 * The Zig side hands back candidates as a JSON string array in memory it owns.
 * Callers here get a plain NULL-terminated `gchar **` freed with g_strfreev, so
 * the JSON and the Zig ownership rule both stop at this file — the same deal
 * transliterator.h makes for transliteration.
 *
 * The lexicon is compiled into the engine (the Avro lexicon), so this needs no
 * database and no spell.db.
 *
 * Shared by Keyboard/ (candidate window) and App/ (the GTK settings app).
 */
#ifndef BYAKARON_LINUX_AUTOCOMPLETE_H
#define BYAKARON_LINUX_AUTOCOMPLETE_H

#include <glib.h>

G_BEGIN_DECLS

typedef struct _BykAutoComplete BykAutoComplete;

/*
 * Open the embedded lexicon, or NULL on failure.
 *
 * The word index behind this lives for the life of the process and is shared by
 * every instance, so the first call pays for building it (~7ms, measured) and
 * later ones are effectively free. Creating one per input context is fine.
 */
BykAutoComplete *byk_autocomplete_new (void);

/* Release an instance from byk_autocomplete_new. NULL is ignored. */
void byk_autocomplete_free (BykAutoComplete *self);

/*
 * Words in the lexicon starting with `prefix`, best first.
 *
 * `prefix` is Bangla (the transliterated text, not the latin the user typed).
 * Returns a NULL-terminated array the caller frees with g_strfreev; an empty
 * array means "no completions", and NULL means the lookup itself failed.
 */
gchar **byk_autocomplete_prefix (BykAutoComplete *self,
                                 const gchar     *prefix,
                                 gint             limit);

/*
 * Parse a JSON array of strings into a NULL-terminated `gchar **`.
 *
 * Exposed only so the parser can be tested directly; byk_autocomplete_prefix is
 * the way to get candidates. Returns NULL if `json` is not an array of strings,
 * or if any element is not valid UTF-8.
 */
gchar **byk_autocomplete_parse_json_array (const gchar *json);

G_END_DECLS

#endif /* BYAKARON_LINUX_AUTOCOMPLETE_H */
