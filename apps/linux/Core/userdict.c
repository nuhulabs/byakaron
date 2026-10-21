#include "userdict.h"

#include <errno.h>
#include <glib/gstdio.h>
#include <stdlib.h>
#include <string.h>

struct _BykUserDict {
    gchar *path;
    GHashTable *words;   /* NFC word -> itself */
    gchar *text;         /* the file's contents as last read or written; "" = absent */
    gint64 checked_at;   /* monotonic µs of the last look at the file */
};

static gchar *
byk_userdict_normalize (const gchar *word)
{
    if (word == NULL || !g_utf8_validate (word, -1, NULL))
        return NULL;
    gchar *trimmed = g_strstrip (g_strdup (word));
    gchar *nfc = *trimmed != '\0' ? g_utf8_normalize (trimmed, -1, G_NORMALIZE_NFC) : NULL;
    g_free (trimmed);
    return nfc;
}

/*
 * The file's current contents, "" when it is missing. A personal dictionary is
 * a few KB, so comparing contents is how changes from the app are noticed:
 * no stat() (Zig's bundled glibc headers gave a `struct stat` smaller than
 * what the system's stat() writes, and the overflow crashed the app) and no
 * GIO (which can load GVfs and block on D-Bus, not something to do on a
 * keystroke).
 */
static gchar *
byk_userdict_read (const gchar *path)
{
    gchar *contents = NULL;
    if (!g_file_get_contents (path, &contents, NULL, NULL))
        return g_strdup ("");
    return contents;
}

static void
byk_userdict_parse (BykUserDict *self, gchar *contents)
{
    g_hash_table_remove_all (self->words);
    g_free (self->text);
    self->text = contents;

    gchar **lines = g_strsplit (contents, "\n", -1);
    for (guint i = 0; lines[i] != NULL; i++) {
        gchar *word = byk_userdict_normalize (lines[i]);
        if (word != NULL)
            g_hash_table_add (self->words, word);
    }
    g_strfreev (lines);
}

static gint
byk_userdict_cmp (gconstpointer a, gconstpointer b)
{
    return g_strcmp0 (*(const gchar * const *) a, *(const gchar * const *) b);
}

static gchar **
byk_userdict_sorted (GHashTable *words)
{
    guint n = 0;
    gchar **list = (gchar **) g_hash_table_get_keys_as_array (words, &n);
    qsort (list, n, sizeof (gchar *), byk_userdict_cmp);
    gchar **copy = g_strdupv (list);
    g_free (list);
    return copy;
}

static gboolean
byk_userdict_save (BykUserDict *self, GHashTable *words, GError **error)
{
    gchar *dir = g_path_get_dirname (self->path);
    if (g_mkdir_with_parents (dir, 0700) != 0) {
        g_set_error (error, G_FILE_ERROR, g_file_error_from_errno (errno),
                     "Could not create %s", dir);
        g_free (dir);
        return FALSE;
    }
    g_free (dir);

    gchar **sorted = byk_userdict_sorted (words);
    gchar *body = g_strjoinv ("\n", sorted);
    gchar *text = *body != '\0' ? g_strconcat (body, "\n", NULL) : g_strdup ("");
    const gboolean ok = g_file_set_contents (self->path, text, -1, error);
    g_free (body);
    g_strfreev (sorted);

    if (ok) {
        g_free (self->text);
        self->text = text;
    } else {
        g_free (text);
    }
    return ok;
}

BykUserDict *
byk_userdict_new (void)
{
    BykUserDict *self = g_new0 (BykUserDict, 1);
    const gchar *env = g_getenv ("BYAKARON_USER_DICT");
    self->path = env != NULL && *env != '\0'
        ? g_strdup (env)
        : g_build_filename (g_get_user_data_dir (), "byakaron", "user-words.txt", NULL);
    self->words = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
    byk_userdict_parse (self, byk_userdict_read (self->path));
    self->checked_at = g_get_monotonic_time ();
    return self;
}

void
byk_userdict_free (BykUserDict *self)
{
    if (self == NULL)
        return;
    g_hash_table_destroy (self->words);
    g_free (self->text);
    g_free (self->path);
    g_free (self);
}

const gchar *
byk_userdict_path (BykUserDict *self)
{
    return self->path;
}

gboolean
byk_userdict_contains (BykUserDict *self, const gchar *word)
{
    if (self == NULL || g_hash_table_size (self->words) == 0)
        return FALSE;
    gchar *nfc = byk_userdict_normalize (word);
    const gboolean found = nfc != NULL && g_hash_table_contains (self->words, nfc);
    g_free (nfc);
    return found;
}

gchar **
byk_userdict_prefix (BykUserDict *self, const gchar *prefix, guint limit)
{
    GPtrArray *out = g_ptr_array_new ();
    gchar *nfc = self != NULL ? byk_userdict_normalize (prefix) : NULL;

    if (nfc != NULL && g_hash_table_size (self->words) > 0) {
        gchar **sorted = byk_userdict_sorted (self->words);
        for (guint i = 0; sorted[i] != NULL && out->len < limit; i++)
            if (g_str_has_prefix (sorted[i], nfc))
                g_ptr_array_add (out, g_strdup (sorted[i]));
        g_strfreev (sorted);
    }
    g_free (nfc);
    g_ptr_array_add (out, NULL);
    return (gchar **) g_ptr_array_free (out, FALSE);
}

gchar **
byk_userdict_words (BykUserDict *self)
{
    return byk_userdict_sorted (self->words);
}

guint
byk_userdict_count (BykUserDict *self)
{
    return self != NULL ? g_hash_table_size (self->words) : 0;
}

/* Write a changed copy; only adopt it once it is on disk, so a failed save
 * cannot leave the app showing a word the keyboard will never see. */
static gboolean
byk_userdict_change (BykUserDict *self, const gchar *word, gboolean add, GError **error)
{
    gchar *nfc = byk_userdict_normalize (word);
    if (nfc == NULL) {
        g_set_error_literal (error, G_FILE_ERROR, G_FILE_ERROR_INVAL, "Not a word");
        return FALSE;
    }
    if (g_hash_table_contains (self->words, nfc) == add) {
        g_free (nfc);
        return TRUE;
    }

    GHashTable *next = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
    GHashTableIter it;
    gpointer key;
    g_hash_table_iter_init (&it, self->words);
    while (g_hash_table_iter_next (&it, &key, NULL))
        if (add || g_strcmp0 (key, nfc) != 0)
            g_hash_table_add (next, g_strdup (key));
    if (add)
        g_hash_table_add (next, g_strdup (nfc));
    g_free (nfc);

    if (!byk_userdict_save (self, next, error)) {
        g_hash_table_destroy (next);
        return FALSE;
    }
    g_hash_table_destroy (self->words);
    self->words = next;
    return TRUE;
}

gboolean
byk_userdict_add (BykUserDict *self, const gchar *word, GError **error)
{
    g_return_val_if_fail (self != NULL, FALSE);
    return byk_userdict_change (self, word, TRUE, error);
}

gboolean
byk_userdict_remove (BykUserDict *self, const gchar *word, GError **error)
{
    g_return_val_if_fail (self != NULL, FALSE);
    return byk_userdict_change (self, word, FALSE, error);
}

gboolean
byk_userdict_reload_if_changed (BykUserDict *self)
{
    if (self == NULL)
        return FALSE;
    const gint64 now = g_get_monotonic_time ();
    if (now - self->checked_at < G_USEC_PER_SEC)
        return FALSE;
    self->checked_at = now;

    gchar *now_text = byk_userdict_read (self->path);
    if (g_strcmp0 (now_text, self->text) == 0) {
        g_free (now_text);
        return FALSE;
    }
    byk_userdict_parse (self, now_text);
    return TRUE;
}
