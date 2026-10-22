#include "learned.h"

#include <errno.h>
#include <glib/gstdio.h>
#include <stdlib.h>
#include <string.h>

struct _BykLearned {
    gchar *path;
    GHashTable *counts;  /* NFC word -> GUINT_TO_POINTER (count) */
    gchar *text;         /* the file as last read or written; "" = absent */
    gint64 checked_at;   /* monotonic µs of the last look at the file */
};

static gchar *
byk_learned_normalize (const gchar *word)
{
    if (word == NULL || *word == '\0' || !g_utf8_validate (word, -1, NULL))
        return NULL;
    return g_utf8_normalize (word, -1, G_NORMALIZE_NFC);
}

/* Read the whole file, "" when missing. Contents are compared rather than
 * stat()ed: see Core/userdict.c for why. */
static gchar *
byk_learned_read (const gchar *path)
{
    gchar *contents = NULL;
    if (!g_file_get_contents (path, &contents, NULL, NULL))
        return g_strdup ("");
    return contents;
}

static void
byk_learned_parse (BykLearned *self, gchar *contents)
{
    g_hash_table_remove_all (self->counts);
    g_free (self->text);
    self->text = contents;

    gchar **lines = g_strsplit (contents, "\n", -1);
    for (guint i = 0; lines[i] != NULL; i++) {
        gchar *tab = strchr (lines[i], '\t');
        if (tab == NULL)
            continue;
        *tab = '\0';
        const guint64 count = g_ascii_strtoull (lines[i], NULL, 10);
        gchar *word = byk_learned_normalize (tab + 1);
        if (word == NULL || count == 0 || count > G_MAXUINT) {
            g_free (word);
            continue;
        }
        g_hash_table_replace (self->counts, word, GUINT_TO_POINTER ((guint) count));
    }
    g_strfreev (lines);
}

typedef struct {
    const gchar *word;
    guint count;
} BykLearnedEntry;

/* Most picked first; ties by word, so the file is stable. */
static gint
byk_learned_cmp (gconstpointer a, gconstpointer b)
{
    const BykLearnedEntry *x = a, *y = b;
    if (x->count != y->count)
        return x->count > y->count ? -1 : 1;
    return g_strcmp0 (x->word, y->word);
}

static gboolean
byk_learned_save (BykLearned *self, GError **error)
{
    GArray *entries = g_array_sized_new (FALSE, FALSE, sizeof (BykLearnedEntry),
                                         g_hash_table_size (self->counts));
    GHashTableIter it;
    gpointer key, value;
    g_hash_table_iter_init (&it, self->counts);
    while (g_hash_table_iter_next (&it, &key, &value)) {
        BykLearnedEntry e = { key, GPOINTER_TO_UINT (value) };
        g_array_append_val (entries, e);
    }
    g_array_sort (entries, byk_learned_cmp);

    /* Keep the most used; drop the tail from memory too, so the file and the
     * ranking agree. */
    if (entries->len > BYK_LEARNED_MAX) {
        for (guint i = BYK_LEARNED_MAX; i < entries->len; i++)
            g_hash_table_remove (self->counts, g_array_index (entries, BykLearnedEntry, i).word);
        g_array_set_size (entries, BYK_LEARNED_MAX);
    }

    GString *text = g_string_new (NULL);
    for (guint i = 0; i < entries->len; i++) {
        const BykLearnedEntry *e = &g_array_index (entries, BykLearnedEntry, i);
        g_string_append_printf (text, "%u\t%s\n", e->count, e->word);
    }
    g_array_free (entries, TRUE);

    gchar *dir = g_path_get_dirname (self->path);
    if (g_mkdir_with_parents (dir, 0700) != 0) {
        g_set_error (error, G_FILE_ERROR, g_file_error_from_errno (errno),
                     "Could not create %s", dir);
        g_free (dir);
        g_string_free (text, TRUE);
        return FALSE;
    }
    g_free (dir);

    if (!g_file_set_contents (self->path, text->str, (gssize) text->len, error)) {
        g_string_free (text, TRUE);
        return FALSE;
    }
    g_free (self->text);
    self->text = g_string_free (text, FALSE);
    return TRUE;
}

BykLearned *
byk_learned_new (void)
{
    BykLearned *self = g_new0 (BykLearned, 1);
    const gchar *env = g_getenv ("BYAKARON_LEARNED");
    self->path = env != NULL && *env != '\0'
        ? g_strdup (env)
        : g_build_filename (g_get_user_data_dir (), "byakaron", "learned-words.txt", NULL);
    self->counts = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
    byk_learned_parse (self, byk_learned_read (self->path));
    self->checked_at = g_get_monotonic_time ();
    return self;
}

void
byk_learned_free (BykLearned *self)
{
    if (self == NULL)
        return;
    g_hash_table_destroy (self->counts);
    g_free (self->text);
    g_free (self->path);
    g_free (self);
}

const gchar *
byk_learned_path (BykLearned *self)
{
    return self->path;
}

guint
byk_learned_count (BykLearned *self, const gchar *word)
{
    if (self == NULL || g_hash_table_size (self->counts) == 0)
        return 0;
    gchar *nfc = byk_learned_normalize (word);
    const guint n = nfc != NULL ? GPOINTER_TO_UINT (g_hash_table_lookup (self->counts, nfc)) : 0;
    g_free (nfc);
    return n;
}

guint
byk_learned_size (BykLearned *self)
{
    return self != NULL ? g_hash_table_size (self->counts) : 0;
}

void
byk_learned_pick (BykLearned *self, const gchar *word)
{
    if (self == NULL)
        return;
    gchar *nfc = byk_learned_normalize (word);
    if (nfc == NULL)
        return;
    const guint n = GPOINTER_TO_UINT (g_hash_table_lookup (self->counts, nfc));
    g_hash_table_replace (self->counts, nfc, GUINT_TO_POINTER (n < G_MAXUINT ? n + 1 : n));
    byk_learned_save (self, NULL);
}

gboolean
byk_learned_clear (BykLearned *self, GError **error)
{
    g_return_val_if_fail (self != NULL, FALSE);
    GHashTable *old = self->counts;
    self->counts = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
    if (!byk_learned_save (self, error)) {
        g_hash_table_destroy (self->counts);
        self->counts = old;
        return FALSE;
    }
    g_hash_table_destroy (old);
    return TRUE;
}

gboolean
byk_learned_reload_if_changed (BykLearned *self)
{
    if (self == NULL)
        return FALSE;
    const gint64 now = g_get_monotonic_time ();
    if (now - self->checked_at < G_USEC_PER_SEC)
        return FALSE;
    self->checked_at = now;

    gchar *now_text = byk_learned_read (self->path);
    if (g_strcmp0 (now_text, self->text) == 0) {
        g_free (now_text);
        return FALSE;
    }
    byk_learned_parse (self, now_text);
    return TRUE;
}
