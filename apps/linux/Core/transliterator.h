/*
 * Thin GLib-friendly wrapper around libbyakaron's transliteration ABI.
 *
 * The Zig engine hands back strings allocated by its own C allocator, which must
 * be released with byakaron_string_free. Callers here get plain g_malloc'd
 * strings instead, so everything in the Linux port frees with g_free and there
 * is exactly one place that has to remember the Zig ownership rule.
 *
 * Shared by Keyboard/ (the IBus engine) and App/ (the GTK settings app).
 */
#ifndef BYAKARON_LINUX_TRANSLITERATOR_H
#define BYAKARON_LINUX_TRANSLITERATOR_H

#include <glib.h>

G_BEGIN_DECLS

typedef struct _BykTransliterator BykTransliterator;

/*
 * Build a reusable Avro (latin -> Bangla) transliterator, or NULL on failure.
 *
 * The underlying engine builds a matching trie once and reuses it, so this is
 * the object to keep alive for the lifetime of an input context rather than
 * recreating per keystroke.
 */
BykTransliterator *byk_transliterator_new (void);

/* Release a transliterator from byk_transliterator_new. NULL is ignored. */
void byk_transliterator_free (BykTransliterator *self);

/*
 * Transliterate a latin string to Bangla.
 *
 * Returns a newly allocated UTF-8 string the caller frees with g_free. An empty
 * input yields an empty (non-NULL) string. Returns NULL only on failure.
 */
gchar *byk_transliterator_run (BykTransliterator *self, const gchar *latin);

G_END_DECLS

#endif /* BYAKARON_LINUX_TRANSLITERATOR_H */
