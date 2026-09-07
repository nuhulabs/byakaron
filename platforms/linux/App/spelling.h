/*
 * "Spelling" page — the editor with an issue list, mirroring the macOS
 * MainView (sidebar of misspellings, red squiggles, a correction bar, Fix All).
 *
 * spell.db is a 364MB file, so the page starts in a loading state and the
 * window hands the engine over once a worker thread has opened it. It also has
 * to render usefully with no database at all, since the input method ships
 * working without one.
 */
#ifndef BYAKARON_LINUX_APP_SPELLING_H
#define BYAKARON_LINUX_APP_SPELLING_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_SPELL_PAGE (byk_spell_page_get_type ())
G_DECLARE_FINAL_TYPE (BykSpellPage, byk_spell_page, BYK, SPELL_PAGE, AdwBin)

/* `engines` is borrowed and must outlive the page. */
GtkWidget *byk_spell_page_new (BykEngines *engines);

/*
 * Leave the loading state. Call once the database has been opened (or has
 * failed to open, with `spell` still NULL in engines).
 */
void byk_spell_page_engine_ready (BykSpellPage *self);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_SPELLING_H */
