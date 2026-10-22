#include "dictionary.h"

#include <string.h>

#include "uiutil.h"

typedef struct {
    ByakaronComposer *composer;
    GtkWidget *dialog;
    GtkWidget *list;
    GtkWidget *empty;
    GtkWidget *count;
    GtkWidget *entry;
    GtkWidget *error;
    GCallback changed;
    gpointer changed_data;
} BykDictionaryView;

static void byk_dictionary_fill (BykDictionaryView *view);

static void
byk_dictionary_notify (BykDictionaryView *view)
{
    if (view->changed != NULL)
        ((void (*) (gpointer)) view->changed) (view->changed_data);
}

static void
byk_dictionary_show_error (BykDictionaryView *view, const gchar *text)
{
    gtk_label_set_text (GTK_LABEL (view->error), text);
    gtk_widget_show (view->error);
}

static void
on_remove_clicked (GtkButton *button, gpointer user_data)
{
    BykDictionaryView *view = user_data;
    const gchar *word = g_object_get_data (G_OBJECT (button), "byk-word");

    if (byakaron_userdict_remove (view->composer, word) < 0) {
        byk_dictionary_show_error (view, "Could not remove the word");
        return;
    }
    gtk_widget_hide (view->error);
    byk_dictionary_fill (view);
    byk_dictionary_notify (view);
}

static void
on_add_activated (GtkWidget *widget, gpointer user_data)
{
    BykDictionaryView *view = user_data;
    (void) widget;

    gchar *word = g_strstrip (g_strdup (gtk_entry_get_text (GTK_ENTRY (view->entry))));

    if (*word != '\0') {
        if (strchr (word, ' ') != NULL || strchr (word, '\t') != NULL) {
            byk_dictionary_show_error (view, "One word at a time, without spaces");
        } else if (byakaron_userdict_add (view->composer, word) < 0) {
            byk_dictionary_show_error (view, "Could not save the word");
        } else {
            gtk_widget_hide (view->error);
            gtk_entry_set_text (GTK_ENTRY (view->entry), "");
            byk_dictionary_fill (view);
            byk_dictionary_notify (view);
        }
    }
    g_free (word);
}

static GtkWidget *
byk_dictionary_row (BykDictionaryView *view, const gchar *word)
{
    GtkWidget *label = gtk_label_new (word);
    gtk_label_set_xalign (GTK_LABEL (label), 0.0);
    gtk_label_set_selectable (GTK_LABEL (label), TRUE);
    byk_css_add (label, "byk-bangla");

    GtkWidget *remove = gtk_button_new_from_icon_name ("user-trash-symbolic", GTK_ICON_SIZE_BUTTON);
    gtk_widget_set_tooltip_text (remove, "Remove from your dictionary");
    gtk_button_set_relief (GTK_BUTTON (remove), GTK_RELIEF_NONE);
    g_object_set_data_full (G_OBJECT (remove), "byk-word", g_strdup (word), g_free);
    g_signal_connect (remove, "clicked", G_CALLBACK (on_remove_clicked), view);

    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_start (box, 12);
    gtk_widget_set_margin_end (box, 6);
    gtk_widget_set_margin_top (box, 4);
    gtk_widget_set_margin_bottom (box, 4);
    byk_box_add_expand (box, label);
    byk_box_add (box, remove);
    return box;
}

static void
byk_dictionary_fill (BykDictionaryView *view)
{
    byk_container_clear (view->list);

    gchar **words = byk_userdict_words (view->composer);
    const guint n = g_strv_length (words);
    for (guint i = 0; i < n; i++)
        gtk_container_add (GTK_CONTAINER (view->list), byk_dictionary_row (view, words[i]));
    g_strfreev (words);

    gchar *count = g_strdup_printf (n == 1 ? "%u saved word" : "%u saved words", n);
    gtk_label_set_text (GTK_LABEL (view->count), count);
    g_free (count);

    gtk_widget_show_all (view->list);
    gtk_widget_set_visible (view->list, n > 0);
    gtk_widget_set_visible (view->empty, n == 0);
}

void
byk_dictionary_show (GtkWindow *parent, ByakaronComposer *composer,
                     GCallback changed, gpointer changed_data)
{
    BykDictionaryView *view = g_new0 (BykDictionaryView, 1);
    view->composer = composer;
    view->changed = changed;
    view->changed_data = changed_data;

    view->dialog = gtk_dialog_new_with_buttons ("Personal Dictionary", parent,
                                                GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT |
                                                GTK_DIALOG_USE_HEADER_BAR,
                                                NULL, NULL);
    gtk_window_set_default_size (GTK_WINDOW (view->dialog), 420, 480);
    g_object_set_data_full (G_OBJECT (view->dialog), "byk-view", view, g_free);

    GtkWidget *intro = gtk_label_new ("Words saved here are never marked as misspelled, "
                                      "and the keyboard suggests them while you type.");
    gtk_label_set_line_wrap (GTK_LABEL (intro), TRUE);
    gtk_label_set_xalign (GTK_LABEL (intro), 0.0);
    byk_css_add (intro, "dim-label");

    view->entry = gtk_entry_new ();
    gtk_entry_set_placeholder_text (GTK_ENTRY (view->entry), "Add a word, e.g. বাংলায়");
    g_signal_connect (view->entry, "activate", G_CALLBACK (on_add_activated), view);
    GtkWidget *add = gtk_button_new_with_label ("Add");
    g_signal_connect (add, "clicked", G_CALLBACK (on_add_activated), view);
    GtkWidget *add_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
    byk_box_add_expand (add_row, view->entry);
    byk_box_add (add_row, add);

    view->error = gtk_label_new (NULL);
    gtk_label_set_xalign (GTK_LABEL (view->error), 0.0);
    byk_css_add (view->error, "error");
    byk_hide_until_shown (view->error);

    view->count = gtk_label_new (NULL);
    gtk_label_set_xalign (GTK_LABEL (view->count), 0.0);
    byk_css_add (view->count, "heading");

    view->list = gtk_list_box_new ();
    gtk_list_box_set_selection_mode (GTK_LIST_BOX (view->list), GTK_SELECTION_NONE);
    view->empty = gtk_label_new ("No saved words yet.\nUse “Add to Dictionary” on the Spelling page, or type one above.");
    gtk_label_set_justify (GTK_LABEL (view->empty), GTK_JUSTIFY_CENTER);
    gtk_label_set_line_wrap (GTK_LABEL (view->empty), TRUE);
    gtk_widget_set_vexpand (view->empty, TRUE);
    byk_css_add (view->empty, "dim-label");

    GtkWidget *list_box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    byk_box_add (list_box, view->list);
    byk_box_add_expand (list_box, view->empty);
    GtkWidget *scroller = byk_scroller (list_box, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand (scroller, TRUE);
    GtkWidget *frame = gtk_frame_new (NULL);
    gtk_container_add (GTK_CONTAINER (frame), scroller);

    gchar *dir = byk_data_dir ();
    gchar *where_text = g_strdup_printf ("Saved in %s/user-words.txt", dir);
    GtkWidget *where = gtk_label_new (where_text);
    g_free (where_text);
    g_free (dir);
    gtk_label_set_xalign (GTK_LABEL (where), 0.0);
    gtk_label_set_ellipsize (GTK_LABEL (where), PANGO_ELLIPSIZE_MIDDLE);
    gtk_label_set_selectable (GTK_LABEL (where), TRUE);
    byk_css_add (where, "dim-label");
    byk_css_add (where, "caption");

    GtkWidget *content = gtk_dialog_get_content_area (GTK_DIALOG (view->dialog));
    gtk_box_set_spacing (GTK_BOX (content), 10);
    gtk_container_set_border_width (GTK_CONTAINER (content), 14);
    byk_box_add (content, intro);
    byk_box_add (content, add_row);
    byk_box_add (content, view->error);
    byk_box_add (content, view->count);
    byk_box_add_expand (content, frame);
    byk_box_add (content, where);

    g_signal_connect (view->dialog, "response", G_CALLBACK (gtk_widget_destroy), NULL);
    gtk_widget_show_all (view->dialog);
    byk_dictionary_fill (view);
    gtk_widget_hide (view->error);
    gtk_widget_grab_focus (view->entry);
}
