/*
 * The header bar's Bangla typing button: ক and A in a circle. The mode in
 * use is the large letter and the other waits small in the corner; they swap
 * places when the mode changes (a click, Ctrl+T). The circle is filled with
 * the accent while Bangla typing is on and only outlined while it is off.
 */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* A toggle button for the stateful boolean action `action` (spell.typing). */
GtkWidget *byk_lang_toggle_new (const gchar *action);

/* How far the swap has come: 0 with A large (off), 1 with ক large (on). For
 * the smoke test and screenshots. */
gdouble byk_lang_toggle_position (GtkWidget *button);

G_END_DECLS
