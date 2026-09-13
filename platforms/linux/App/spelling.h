#ifndef BYAKARON_LINUX_APP_SPELLING_H
#define BYAKARON_LINUX_APP_SPELLING_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_SPELL_PAGE (byk_spell_page_get_type ())
G_DECLARE_FINAL_TYPE (BykSpellPage, byk_spell_page, BYK, SPELL_PAGE, GtkBox)

/* `engines` is borrowed and must outlive the page. */
GtkWidget *byk_spell_page_new (BykEngines *engines);

/*
 * Leave the loading state. Call once the database has been opened (or has
 * failed to open, with `spell` still NULL in engines).
 */
void byk_spell_page_engine_ready (BykSpellPage *self);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_SPELLING_H */
