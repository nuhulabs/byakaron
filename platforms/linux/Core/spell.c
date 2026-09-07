#include "spell.h"

#include "autocomplete.h"
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
        g_warning ("byakaron: spell.db not found "
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

gint
byk_spell_is_correct (BykSpell *self, const gchar *word)
{
    g_return_val_if_fail (self != NULL, -1);
    g_return_val_if_fail (word != NULL, -1);
    return byakaron_spell_is_correct (self->engine, word);
}

gchar **
byk_spell_suggest (BykSpell *self, const gchar *word, gint limit)
{
    g_return_val_if_fail (self != NULL, NULL);
    g_return_val_if_fail (word != NULL, NULL);

    if (*word == '\0')
        return g_new0 (gchar *, 1);

    char *json = byakaron_spell_suggest (self->engine, word, limit);
    if (json == NULL)
        return NULL;

    /* Same JSON string-array as autocomplete; one parser, one ownership rule. */
    gchar **words = byk_autocomplete_parse_json_array (json);
    byakaron_string_free (json);

    if (words == NULL)
        g_warning ("byakaron: could not parse spell suggestions");

    return words;
}
