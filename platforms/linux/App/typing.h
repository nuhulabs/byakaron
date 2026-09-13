#ifndef BYAKARON_LINUX_APP_TYPING_H
#define BYAKARON_LINUX_APP_TYPING_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_TYPING_PAGE (byk_typing_page_get_type ())
G_DECLARE_FINAL_TYPE (BykTypingPage, byk_typing_page, BYK, TYPING_PAGE, GtkBox)

GtkWidget *byk_typing_page_new (void);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_TYPING_H */
