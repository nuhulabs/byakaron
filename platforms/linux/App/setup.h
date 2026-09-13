#ifndef BYAKARON_LINUX_APP_SETUP_H
#define BYAKARON_LINUX_APP_SETUP_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_SETUP_PAGE (byk_setup_page_get_type ())
G_DECLARE_FINAL_TYPE (BykSetupPage, byk_setup_page, BYK, SETUP_PAGE, GtkBox)

GtkWidget *byk_setup_page_new (void);

/* Re-read the keyboard status. Called when the page comes into view, since
 * adding an input source happens outside this app. */
void byk_setup_page_refresh (BykSetupPage *self);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_SETUP_H */
