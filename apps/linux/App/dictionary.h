/*
 * The personal dictionary: the words the user has saved as correct, with a
 * way to add one by hand and remove any. They go through the composer
 * (byakaron_userdict_*), into user-words.txt in the data directory, which the
 * keyboard re-reads at its next word, so changes reach it without a restart.
 *
 * One view, two homes: the Dictionary tab of Preferences embeds it, and the
 * main menu's Personal Dictionary… shows it in a dialog of its own.
 */
#ifndef BYAKARON_LINUX_APP_DICTIONARY_H
#define BYAKARON_LINUX_APP_DICTIONARY_H

#include <gtk/gtk.h>

#include "composer.h"

G_BEGIN_DECLS

/*
 * The add row, the word list (or its empty state) and where the file lives,
 * as one box with no margins of its own. `composer` is borrowed and may be
 * NULL (then nothing can be added). `changed` runs after every add / remove,
 * e.g. to re-check the Spelling page.
 */
GtkWidget *byk_dictionary_view_new (ByakaronComposer *composer,
                                    GCallback changed, gpointer changed_data);

/* Re-read the words, e.g. after the Spelling page saved one. */
void byk_dictionary_view_refresh (GtkWidget *view);

/* Put the cursor in the add field. */
void byk_dictionary_view_focus (GtkWidget *view);

/* The same view in a modal dialog over `parent`. */
void byk_dictionary_show (GtkWindow *parent, ByakaronComposer *composer,
                          GCallback changed, gpointer changed_data);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_DICTIONARY_H */
