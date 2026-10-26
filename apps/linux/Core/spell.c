#include "spell.h"

#include <string.h>

#include "composer.h"
#include "byakaron.h"

struct _BykSpell {
    ByakaronSpell *engine;
};

gchar *
byk_spell_locate_db (void)
{
    const gchar *env = g_getenv ("BYAKARON_SPELL_DB");
    if (env != NULL && *env != '\0' && g_file_test (env, G_FILE_TEST_IS_REGULAR))
        return g_strdup (env);

    if (g_file_test (BYK_SPELL_DB_SYSTEM, G_FILE_TEST_IS_REGULAR))
        return g_strdup (BYK_SPELL_DB_SYSTEM);

    return NULL;
}

BykSpell *
byk_spell_new (const gchar *db_path)
{
    gchar *owned = NULL;
    const gchar *path = db_path;

    if (path == NULL || *path == '\0') {
        owned = byk_spell_locate_db ();
        path = owned;
    }

    if (path == NULL) {
        g_warning ("byakaron: Byakaron.db not found "
                   "(set BYAKARON_SPELL_DB or install to %s)",
                   BYK_SPELL_DB_SYSTEM);
        return NULL;
    }

    ByakaronSpell *engine = byakaron_spell_create (path);
    if (engine == NULL) {
        g_warning ("byakaron: byakaron_spell_create failed for %s", path);
        g_free (owned);
        return NULL;
    }
    g_free (owned);

    BykSpell *self = g_new0 (BykSpell, 1);
    self->engine = engine;
    return self;
}

void
byk_spell_free (BykSpell *self)
{
    if (self == NULL)
        return;

    byakaron_spell_destroy (self->engine);
    g_free (self);
}

/*
 * Byakaron.db spells ড় ঢ় য় as the single code points U+09DC/09DD/09DF, which is
 * also what the keyboard types. Unicode NFC does the opposite — those three are
 * composition exclusions, so normalised text (most web pages, other keyboards)
 * carries ড/ঢ/য + nukta U+09BC — and without this every pasted পড়, আমায় was
 * reported as misspelled. Fold to the dictionary's form before asking.
 */
static gchar *
byk_spell_fold_nukta (const gchar *word)
{
    GString *out = g_string_sized_new (strlen (word));

    for (const gchar *p = word; *p != '\0'; p = g_utf8_next_char (p)) {
        const gunichar c = g_utf8_get_char (p);
        const gchar *next = g_utf8_next_char (p);
        const gboolean nukta = *next != '\0' && g_utf8_get_char (next) == 0x09BC;

        if (nukta && (c == 0x09A1 || c == 0x09A2 || c == 0x09AF)) {
            g_string_append_unichar (out, c == 0x09A1 ? 0x09DC
                                          : c == 0x09A2 ? 0x09DD
                                                        : 0x09DF);
            p = next; /* skip the nukta too */
        } else {
            g_string_append_unichar (out, c);
        }
    }

    return g_string_free (out, FALSE);
}

gint
byk_spell_is_correct (BykSpell *self, const gchar *word)
{
    g_return_val_if_fail (self != NULL, -1);
    g_return_val_if_fail (word != NULL, -1);

    /* The engine traps (SIGILL) on malformed UTF-8 instead of returning. */
    if (!g_utf8_validate (word, -1, NULL))
        return -1;

    gchar *folded = byk_spell_fold_nukta (word);
    const gint correct = byakaron_spell_is_correct (self->engine, folded);
    g_free (folded);
    return correct;
}

gchar **
byk_spell_suggest (BykSpell *self, const gchar *word, gint limit)
{
    g_return_val_if_fail (self != NULL, NULL);
    g_return_val_if_fail (word != NULL, NULL);

    if (*word == '\0')
        return g_new0 (gchar *, 1);
    if (!g_utf8_validate (word, -1, NULL))
        return NULL;

    gchar *folded = byk_spell_fold_nukta (word);
    char *json = byakaron_spell_suggest (self->engine, folded, limit);
    g_free (folded);
    if (json == NULL)
        return NULL;

    /* The ABI's JSON string array; one parser, one ownership rule. */
    gchar **words = byk_parse_json_strings (json);
    byakaron_string_free (json);

    if (words == NULL)
        g_warning ("byakaron: could not parse spell suggestions");

    return words;
}
