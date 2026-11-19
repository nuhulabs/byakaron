#include "layout.h"

#include "byakaron_strings.h"
#include "uiutil.h"

/* `glyphs` sizes every Bangla label in a section alike, so the keys line up in
 * a column even when one entry (আ / কা, ক্য য-ফলা) is wider than the rest. */
static GtkWidget *
byk_layout_cell (const ByakaronLayoutEntry *entry, GtkSizeGroup *glyphs)
{
    GtkWidget *bangla = gtk_label_new (entry->bangla);
    gtk_label_set_xalign (GTK_LABEL (bangla), 0.0);
    gtk_widget_set_size_request (bangla, 48, -1);
    gtk_size_group_add_widget (glyphs, bangla);
    byk_css_add (bangla, "byk-layout-glyph");

    /* Full contrast, not dim-label: the keys are what people come here for. */
    GtkWidget *keys = gtk_label_new (entry->keys);
    gtk_label_set_xalign (GTK_LABEL (keys), 0.0);
    byk_css_add (keys, "monospace");
    byk_css_add (keys, "byk-layout-keys");
    gtk_widget_set_hexpand (keys, TRUE);

    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
    byk_box_add (box, bangla);
    byk_box_add_expand (box, keys);
    gtk_widget_set_margin_top (box, 4);
    gtk_widget_set_margin_bottom (box, 4);

    return box;
}

/* Section `index` of the shared key map (src/Composer/Layout.zig), or NULL
 * past the end. Its order is varga order, five to a row, the way the
 * alphabet is taught: the flow box shows up to five per line, so a wide
 * window reads ক খ গ ঘ ঙ across. */
static GtkWidget *
byk_layout_group (gsize index)
{
    const char *title = NULL;
    size_t count = 0;
    if (byakaron_layout_section_info (index, &title, &count) != 0)
        return NULL;

    GtkWidget *box = byk_section (title, NULL);

    /* A flow box rather than a fixed grid: the macOS version uses an adaptive
     * grid, and the same number of columns cannot suit both a 40-entry
     * consonant table and a 10-entry number row. */
    GtkWidget *flow = gtk_flow_box_new ();
    gtk_flow_box_set_selection_mode (GTK_FLOW_BOX (flow), GTK_SELECTION_NONE);
    gtk_flow_box_set_homogeneous (GTK_FLOW_BOX (flow), TRUE);
    gtk_flow_box_set_min_children_per_line (GTK_FLOW_BOX (flow), 2);
    gtk_flow_box_set_max_children_per_line (GTK_FLOW_BOX (flow), 5);
    gtk_flow_box_set_column_spacing (GTK_FLOW_BOX (flow), 18);

    GtkSizeGroup *glyphs = gtk_size_group_new (GTK_SIZE_GROUP_HORIZONTAL);
    for (size_t i = 0; i < count; i++) {
        ByakaronLayoutEntry entry;
        if (byakaron_layout_entry (index, i, &entry) == 0)
            gtk_container_add (GTK_CONTAINER (flow), byk_layout_cell (&entry, glyphs));
    }
    g_object_unref (glyphs); /* the labels keep it alive */

    byk_box_add (box, flow);
    return box;
}

GtkWidget *
byk_layout_page_new (void)
{
    GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_top (column, 12);
    gtk_widget_set_margin_bottom (column, 18);

    byk_box_add (column, byk_section (NULL, byk_str (BYK_STR_LAYOUT_HINT)));

    const gsize n = byakaron_layout_section_count ();
    for (gsize i = 0; i < n; i++) {
        GtkWidget *group = byk_layout_group (i);
        if (group != NULL)
            byk_box_add (column, group);
    }

    return byk_scroller (column, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
}
