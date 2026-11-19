/*
 * "Layout" page: the Avro phonetic key map, as a lookup table.
 *
 * The table is the engine's own (src/Composer/Layout.zig, read through
 * byakaron_layout_*), the one every platform's Layout tab draws, so the
 * platforms cannot drift apart from each other or from what the keyboard types.
 */
#ifndef BYAKARON_LINUX_APP_LAYOUT_H
#define BYAKARON_LINUX_APP_LAYOUT_H

#include "app.h"

G_BEGIN_DECLS

GtkWidget *byk_layout_page_new (void);

G_END_DECLS

#endif /* BYAKARON_LINUX_APP_LAYOUT_H */
