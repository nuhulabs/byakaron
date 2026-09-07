/*
 * "Write" page — a working phonetic composer, so Bangla can be typed here
 * without adding an input source first.
 *
 * It is deliberately a composer rather than a two-pane converter: a converter
 * would transliterate the whole text on every keystroke and leave the
 * candidate list decorative, since clicking a Bangla completion cannot be
 * mapped back to the latin that produced it. Composing one word at a time is
 * also what the IBus engine does, so this page doubles as an honest preview of
 * the keyboard.
 */
#ifndef BYAKARON_LINUX_APP_TYPING_H
#define BYAKARON_LINUX_APP_TYPING_H

#include "app.h"

G_BEGIN_DECLS

#define BYK_TYPE_TYPING_PAGE (byk_typing_page_get_type ())
G_DECLARE_FINAL_TYPE (BykTypingPage, byk_typing_page, BYK, TYPING_PAGE, AdwBin)

/* `engines` is borrowed and must outlive the page. */
GtkWidget *byk_typing_page_new (BykEngines *engines);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_TYPING_H */
