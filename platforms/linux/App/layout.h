/*
 * "Layout" page — the Avro phonetic key map, as a lookup table.
 *
 * Static reference, no engine calls. The data is a transcription of the macOS
 * LayoutTab so the two platforms document the same keyboard; if the mappings
 * ever diverge, one of the two is a bug.
 */
#ifndef BYAKARON_LINUX_APP_LAYOUT_H
#define BYAKARON_LINUX_APP_LAYOUT_H

#include "app.h"

G_BEGIN_DECLS

GtkWidget *byk_layout_page_new (void);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_LAYOUT_H */
