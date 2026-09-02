#include "transliterator.h"

#include <string.h>

#include "byakaron.h"

struct _BykTransliterator {
    ByakaronEngine *engine;
};

BykTransliterator *
byk_transliterator_new (void)
{
    ByakaronEngine *engine = byakaron_engine_create (BYAKARON_MODE_AVRO);
    if (engine == NULL) {
        g_warning ("byakaron: byakaron_engine_create(AVRO) failed");
        return NULL;
    }

    BykTransliterator *self = g_new0 (BykTransliterator, 1);
    self->engine = engine;
    return self;
}

void
byk_transliterator_free (BykTransliterator *self)
{
    if (self == NULL)
        return;

    byakaron_engine_destroy (self->engine);
    g_free (self);
}

gchar *
byk_transliterator_run (BykTransliterator *self, const gchar *latin)
{
    g_return_val_if_fail (self != NULL, NULL);
    g_return_val_if_fail (latin != NULL, NULL);

    /* The engine is fine with an empty string, but skipping the FFI round trip
     * for the common "buffer just got cleared" case is free. */
    if (*latin == '\0')
        return g_strdup ("");

    char *raw = byakaron_engine_transliterate (self->engine, latin);
    if (raw == NULL)
        return NULL;

    /* Hand back g_malloc memory and give the Zig allocation straight back. */
    gchar *out = g_strdup (raw);
    byakaron_string_free (raw);
    return out;
}
