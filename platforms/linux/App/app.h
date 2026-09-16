/*
 * Vocabulary shared by every page of the Byakaron GTK app.
 *
 * The spell engine handle is created once by the window and borrowed by the
 * Spelling page, because spell.db is a 364MB file. Nothing here owns it.
 */
#ifndef BYAKARON_LINUX_APP_H
#define BYAKARON_LINUX_APP_H

#include <gtk/gtk.h>

#include "autocomplete.h"
#include "spell.h"
#include "transliterator.h"

G_BEGIN_DECLS

#define BYK_APP_ID      "dev.nuhu.labs.Byakaron"
#define BYK_APP_VERSION "0.1.4"

#define BYK_URL_GITHUB  "https://github.com/nuhulabs/byakaron"
#define BYK_URL_WEBSITE "https://nuhulabs.github.io"

/*
 * `spell` is NULL until the database has finished opening on a worker thread,
 * and stays NULL when no spell.db is installed — every page has to cope with
 * that, the same way the input method types without one.
 */
typedef struct {
    BykTransliterator *transliterator;
    BykAutoComplete *autocomplete;
    BykSpell *spell;
} BykEngines;

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_H */
