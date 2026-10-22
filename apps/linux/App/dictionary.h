/*
 * "Personal Dictionary" window: the words the user has saved as correct, with
 * a way to add one by hand and remove any. They go through the composer
 * (byakaron_userdict_*), into user-words.txt in the data directory, which the
 * keyboard re-reads at its next word, so changes reach it without a restart.
 */
#ifndef BYAKARON_LINUX_APP_DICTIONARY_H
#define BYAKARON_LINUX_APP_DICTIONARY_H

#include <gtk/gtk.h>

#include "composer.h"

G_BEGIN_DECLS

/* `changed` runs after every add / remove, e.g. to re-check the Spelling page. */
void byk_dictionary_show (GtkWindow *parent, ByakaronComposer *composer,
                          GCallback changed, gpointer changed_data);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_DICTIONARY_H */
