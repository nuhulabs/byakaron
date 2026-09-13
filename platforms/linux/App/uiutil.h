/*
 * GTK3 helpers so the companion app runs on Ubuntu 20.04, 22.04, and 24.04.
 * GTK4 and libadwaita 1.4 are not available on 20.04 / 22.04.
 */
#ifndef BYAKARON_LINUX_APP_UIUTIL_H
#define BYAKARON_LINUX_APP_UIUTIL_H

#include <gtk/gtk.h>

G_BEGIN_DECLS

void byk_css_add (GtkWidget *widget, const gchar *class_name);
void byk_css_remove (GtkWidget *widget, const gchar *class_name);
void byk_box_add (GtkWidget *box, GtkWidget *child);
void byk_box_add_expand (GtkWidget *box, GtkWidget *child);
void byk_container_clear (GtkWidget *container);
void byk_container_set_child (GtkWidget *container, GtkWidget *child);
void byk_clipboard_set (GtkWidget *widget, const gchar *text);
void byk_toast_show (GtkLabel *label, const gchar *message);
void byk_hide_until_shown (GtkWidget *widget);
GtkWidget *byk_icon_button (const gchar *icon_name);
GtkWidget *byk_scroller (GtkWidget *child, GtkPolicyType h, GtkPolicyType v);
GtkWidget *byk_section (const gchar *title, const gchar *description);
GtkWidget *byk_status_page (const gchar *icon, const gchar *title, const gchar *body);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_UIUTIL_H */
