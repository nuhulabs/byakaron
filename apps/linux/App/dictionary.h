/*
 * "Personal Dictionary" window: the words the user has saved as correct, with
 * a way to add one by hand and remove any. The keyboard re-reads the same file
 * (Core/userdict.h), so changes reach it without a restart.
 */
#ifndef BYAKARON_LINUX_APP_DICTIONARY_H
#define BYAKARON_LINUX_APP_DICTIONARY_H

#include <gtk/gtk.h>

#include "userdict.h"

G_BEGIN_DECLS

/* `changed` runs after every add / remove, e.g. to re-check the Spelling page. */
void byk_dictionary_show (GtkWindow *parent, BykUserDict *dict,
                          GCallback changed, gpointer changed_data);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_DICTIONARY_H */
