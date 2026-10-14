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
#include "userdict.h"

G_BEGIN_DECLS

#define BYK_APP_ID      "dev.nuhu.labs.Byakaron"
#define BYK_APP_VERSION "0.1.9"

/* Public pages only: nuhulabs/byakaron is private, so a link to it is a 404
 * for everyone who installs the app. */
#define BYK_URL_WEBSITE   "https://nuhulabs.com/byakaron"
#define BYK_URL_DOWNLOADS "https://github.com/nuhulabs/Byakaron-Assets/releases"

/* What Setup copies when the keyboard is missing: the same one-liner the
 * website gives, since the app has no source checkout to run a script from. */
#define BYK_INSTALL_COMMAND \
    "curl -fsSL https://nuhulabs.com/byakaron/install.sh | sudo bash"

/*
 * `spell` is NULL until the database has finished opening on a worker thread,
 * and stays NULL when no spell.db is installed — every page has to cope with
 * that, the same way the input method types without one.
 */
typedef struct {
    BykTransliterator *transliterator;
    BykAutoComplete *autocomplete;
    BykSpell *spell;
    /* The personal dictionary; always present (an empty file is fine). The
     * keyboard reads the same file. */
    BykUserDict *userdict;
} BykEngines;

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_H */
