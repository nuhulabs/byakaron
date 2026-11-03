#include "uiutil.h"

void
byk_css_add (GtkWidget *widget, const gchar *class_name)
{
    gtk_style_context_add_class (gtk_widget_get_style_context (widget), class_name);
}

void
byk_css_remove (GtkWidget *widget, const gchar *class_name)
{
    gtk_style_context_remove_class (gtk_widget_get_style_context (widget), class_name);
}

void
byk_box_add (GtkWidget *box, GtkWidget *child)
{
    gtk_box_pack_start (GTK_BOX (box), child, FALSE, FALSE, 0);
}

void
byk_box_add_expand (GtkWidget *box, GtkWidget *child)
{
    gtk_box_pack_start (GTK_BOX (box), child, TRUE, TRUE, 0);
}

void
byk_container_clear (GtkWidget *container)
{
    GList *children = gtk_container_get_children (GTK_CONTAINER (container));
    for (GList *l = children; l != NULL; l = l->next)
        gtk_widget_destroy (GTK_WIDGET (l->data));
    g_list_free (children);
}

void
byk_container_set_child (GtkWidget *container, GtkWidget *child)
{
    gtk_container_add (GTK_CONTAINER (container), child);
}

void
byk_clipboard_set (GtkWidget *widget, const gchar *text)
{
    gtk_clipboard_set_text (
        gtk_widget_get_clipboard (widget, GDK_SELECTION_CLIPBOARD), text, -1);
}

static gboolean
on_toast_timeout (gpointer user_data)
{
    GtkWidget *label = GTK_WIDGET (user_data);
    gtk_label_set_text (GTK_LABEL (label), "");
    gtk_widget_hide (label);
    g_object_set_data (G_OBJECT (label), "byk-toast-id", NULL);
    return G_SOURCE_REMOVE;
}

void
byk_toast_show (GtkLabel *label, const gchar *message)
{
    guint old = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (label), "byk-toast-id"));
    if (old != 0)
        g_source_remove (old);

    gtk_label_set_text (label, message);
    gtk_widget_show (GTK_WIDGET (label));
    guint id = g_timeout_add (2500, on_toast_timeout, label);
    g_object_set_data (G_OBJECT (label), "byk-toast-id", GUINT_TO_POINTER (id));
}

void
byk_hide_until_shown (GtkWidget *widget)
{
    gtk_widget_set_no_show_all (widget, TRUE);
    gtk_widget_hide (widget);
}

GtkWidget *
byk_icon_button (const gchar *icon_name)
{
    return gtk_button_new_from_icon_name (icon_name, GTK_ICON_SIZE_BUTTON);
}

GtkWidget *
byk_scroller (GtkWidget *child, GtkPolicyType h, GtkPolicyType v)
{
    GtkWidget *scroller = gtk_scrolled_window_new (NULL, NULL);
    gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller), h, v);
    gtk_container_add (GTK_CONTAINER (scroller), child);
    return scroller;
}

GtkWidget *
byk_section (const gchar *title, const gchar *description)
{
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
    if (title != NULL) {
        GtkWidget *label = gtk_label_new (title);
        byk_css_add (label, "heading");
        gtk_widget_set_halign (label, GTK_ALIGN_START);
        byk_box_add (box, label);
    }
    if (description != NULL) {
        GtkWidget *label = gtk_label_new (description);
        byk_css_add (label, "dim-label");
        gtk_label_set_line_wrap (GTK_LABEL (label), TRUE);
        gtk_label_set_xalign (GTK_LABEL (label), 0.0);
        byk_box_add (box, label);
    }
    gtk_widget_set_margin_top (box, 12);
    gtk_widget_set_margin_bottom (box, 8);
    gtk_widget_set_margin_start (box, 18);
    gtk_widget_set_margin_end (box, 18);
    return box;
}

GtkWidget *
byk_status_page (const gchar *icon, const gchar *title, const gchar *body)
{
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
    gtk_widget_set_halign (box, GTK_ALIGN_CENTER);
    gtk_widget_set_vexpand (box, TRUE);
    gtk_widget_set_margin_start (box, 24);
    gtk_widget_set_margin_end (box, 24);

    if (icon != NULL) {
        GtkWidget *image = gtk_image_new_from_icon_name (icon, GTK_ICON_SIZE_DIALOG);
        gtk_image_set_pixel_size (GTK_IMAGE (image), 48);
        byk_css_add (image, "dim-label");
        byk_box_add (box, image);
    }
    if (title != NULL) {
        GtkWidget *label = gtk_label_new (title);
        byk_css_add (label, "heading");
        gtk_label_set_justify (GTK_LABEL (label), GTK_JUSTIFY_CENTER);
        byk_box_add (box, label);
    }
    if (body != NULL) {
        GtkWidget *label = gtk_label_new (body);
        byk_css_add (label, "dim-label");
        gtk_label_set_line_wrap (GTK_LABEL (label), TRUE);
        gtk_label_set_justify (GTK_LABEL (label), GTK_JUSTIFY_CENTER);
        gtk_label_set_max_width_chars (GTK_LABEL (label), 48);
        /* Bodies can carry a command to paste into a terminal. */
        gtk_label_set_selectable (GTK_LABEL (label), TRUE);
        byk_box_add (box, label);
    }
    return box;
}

/* ── settings-style rows (Setup, Settings) ──────────────────────────────── */

GtkWidget *
byk_row (GtkWidget *prefix, const gchar *title, const gchar *subtitle, GtkWidget *suffix)
{
    GtkWidget *labels = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
    GtkWidget *title_w = gtk_label_new (title);
    gtk_label_set_xalign (GTK_LABEL (title_w), 0.0);
    gtk_label_set_line_wrap (GTK_LABEL (title_w), TRUE);
    byk_box_add (labels, title_w);

    GtkWidget *sub_w = NULL;
    if (subtitle != NULL) {
        sub_w = gtk_label_new (subtitle);
        byk_css_add (sub_w, "dim-label");
        gtk_label_set_xalign (GTK_LABEL (sub_w), 0.0);
        gtk_label_set_line_wrap (GTK_LABEL (sub_w), TRUE);
        byk_box_add (labels, sub_w);
    }

    GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_top (row, 8);
    gtk_widget_set_margin_bottom (row, 8);
    gtk_widget_set_margin_start (row, 12);
    gtk_widget_set_margin_end (row, 12);
    if (prefix != NULL) {
        gtk_widget_set_valign (prefix, GTK_ALIGN_CENTER);
        byk_box_add (row, prefix);
    }
    gtk_widget_set_hexpand (labels, TRUE);
    /* Centred, or a one-line title sits above the middle of a taller button. */
    gtk_widget_set_valign (labels, GTK_ALIGN_CENTER);
    byk_box_add_expand (row, labels);
    if (suffix != NULL) {
        gtk_widget_set_valign (suffix, GTK_ALIGN_CENTER);
        byk_box_add (row, suffix);
    }

    g_object_set_data (G_OBJECT (row), "byk-title", title_w);
    g_object_set_data (G_OBJECT (row), "byk-subtitle", sub_w);
    return row;
}

GtkWidget *
byk_framed_list (const gchar *title, const gchar *description, GtkWidget **out_box)
{
    GtkWidget *outer = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start (outer, 18);
    gtk_widget_set_margin_end (outer, 18);
    gtk_widget_set_margin_top (outer, 12);

    if (title != NULL) {
        GtkWidget *label = gtk_label_new (title);
        byk_css_add (label, "heading");
        gtk_widget_set_halign (label, GTK_ALIGN_START);
        byk_box_add (outer, label);
    }
    if (description != NULL) {
        GtkWidget *label = gtk_label_new (description);
        byk_css_add (label, "dim-label");
        gtk_label_set_line_wrap (GTK_LABEL (label), TRUE);
        gtk_label_set_xalign (GTK_LABEL (label), 0.0);
        byk_box_add (outer, label);
    }

    GtkWidget *list = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *frame = gtk_frame_new (NULL);
    gtk_container_add (GTK_CONTAINER (frame), list);
    byk_box_add (outer, frame);
    *out_box = list;
    return outer;
}
