#include "typing.h"

/* Candidates per row, matching the input method's page size so the 1-9 hint
 * here means the same thing it does while typing in another application. */
#define BYK_CANDIDATE_LIMIT 9

struct _BykTypingPage {
    AdwBin parent_instance;

    BykEngines *engines;

    GtkWidget *entry;      /* latin for the word being composed */
    GtkWidget *preedit;    /* its Bangla, updated on every keystroke */
    GtkWidget *candidates; /* GtkBox of buttons, one per completion */
    GtkWidget *output;     /* GtkTextView holding what has been committed */
    GtkWidget *counter;

    AdwToastOverlay *toasts;

    /* Completions currently on screen, so a number key can pick one without
     * walking the button box. NULL-terminated, owned. */
    gchar **shown;
};

G_DEFINE_FINAL_TYPE (BykTypingPage, byk_typing_page, ADW_TYPE_BIN)

/* ── committing ──────────────────────────────────────────────────────────── */

static void
byk_typing_page_append (BykTypingPage *self, const gchar *text)
{
    GtkTextBuffer *buffer = gtk_text_view_get_buffer (GTK_TEXT_VIEW (self->output));
    GtkTextIter end;

    gtk_text_buffer_get_end_iter (buffer, &end);
    gtk_text_buffer_insert (buffer, &end, text, -1);

    /* Keep the caret at the end so long text scrolls into view as it grows. */
    gtk_text_buffer_get_end_iter (buffer, &end);
    gtk_text_buffer_place_cursor (buffer, &end);
    gtk_text_view_scroll_to_iter (GTK_TEXT_VIEW (self->output), &end, 0.0, FALSE, 0.0, 0.0);
}

/* Commit `word` (already Bangla) plus an optional separator, and start fresh. */
static void
byk_typing_page_commit (BykTypingPage *self, const gchar *word, const gchar *suffix)
{
    if (word == NULL || *word == '\0') {
        /* Nothing composed: a bare Space or Enter is still a real keystroke. */
        if (suffix != NULL)
            byk_typing_page_append (self, suffix);
        return;
    }

    gchar *text = suffix != NULL ? g_strconcat (word, suffix, NULL) : g_strdup (word);
    byk_typing_page_append (self, text);
    g_free (text);

    gtk_editable_set_text (GTK_EDITABLE (self->entry), "");
}

/* ── candidates ──────────────────────────────────────────────────────────── */

static void
on_candidate_clicked (GtkButton *button, gpointer user_data)
{
    BykTypingPage *self = BYK_TYPING_PAGE (user_data);

    /* No trailing space: picking a word is not finishing a sentence — the same
     * call the IBus engine makes. */
    byk_typing_page_commit (self, gtk_button_get_label (button), NULL);
}

static void
byk_typing_page_clear_candidates (BykTypingPage *self)
{
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child (self->candidates)) != NULL)
        gtk_box_remove (GTK_BOX (self->candidates), child);

    g_clear_pointer (&self->shown, g_strfreev);
    gtk_widget_set_visible (self->candidates, FALSE);
}

static void
byk_typing_page_show_candidates (BykTypingPage *self, const gchar *bangla)
{
    byk_typing_page_clear_candidates (self);

    if (self->engines->autocomplete == NULL || bangla == NULL || *bangla == '\0')
        return;

    gchar **words = byk_autocomplete_prefix (self->engines->autocomplete,
                                             bangla,
                                             BYK_CANDIDATE_LIMIT);
    if (words == NULL)
        return;
    if (words[0] == NULL) {
        g_strfreev (words);
        return;
    }

    for (guint i = 0; words[i] != NULL; i++) {
        GtkWidget *button = gtk_button_new_with_label (words[i]);

        /* The digit is the point of the label: it is the key that picks this
         * word both here and in the input method. */
        gchar *tooltip = g_strdup_printf ("Press %u to insert %s", i + 1, words[i]);
        gtk_widget_set_tooltip_text (button, tooltip);
        g_free (tooltip);

        gtk_widget_add_css_class (button, "byk-candidate");
        g_signal_connect (button, "clicked", G_CALLBACK (on_candidate_clicked), self);
        gtk_box_append (GTK_BOX (self->candidates), button);
    }

    self->shown = words;
    gtk_widget_set_visible (self->candidates, TRUE);
}

/* ── live transliteration ────────────────────────────────────────────────── */

/* The Bangla for what is in the entry right now, or NULL. Caller frees. */
static gchar *
byk_typing_page_bangla (BykTypingPage *self)
{
    const gchar *latin = gtk_editable_get_text (GTK_EDITABLE (self->entry));
    if (latin == NULL || *latin == '\0')
        return NULL;

    return byk_transliterator_run (self->engines->transliterator, latin);
}

static void
on_entry_changed (GtkEditable *editable, gpointer user_data)
{
    BykTypingPage *self = BYK_TYPING_PAGE (user_data);
    (void) editable;

    gchar *bangla = byk_typing_page_bangla (self);

    if (bangla == NULL || *bangla == '\0') {
        /* Keep the row's height so the layout does not jump on every word. */
        gtk_label_set_text (GTK_LABEL (self->preedit), "\u200b");
        gtk_widget_remove_css_class (self->preedit, "byk-preedit-filled");
    } else {
        gtk_label_set_text (GTK_LABEL (self->preedit), bangla);
        gtk_widget_add_css_class (self->preedit, "byk-preedit-filled");
    }

    byk_typing_page_show_candidates (self, bangla);
    g_free (bangla);
}

/* ── key handling (mirrors Keyboard/engine.c) ────────────────────────────── */

/* 0-based candidate index for a number key, or -1. `0` is never a selector,
 * exactly as in the input method, so it stays available as ০. */
static gint
byk_candidate_index (guint keyval)
{
    if (keyval >= GDK_KEY_1 && keyval <= GDK_KEY_9)
        return (gint) (keyval - GDK_KEY_1);
    if (keyval >= GDK_KEY_KP_1 && keyval <= GDK_KEY_KP_9)
        return (gint) (keyval - GDK_KEY_KP_1);
    return -1;
}

static gboolean
on_entry_key_pressed (GtkEventControllerKey *controller,
                      guint keyval,
                      guint keycode,
                      GdkModifierType state,
                      gpointer user_data)
{
    BykTypingPage *self = BYK_TYPING_PAGE (user_data);
    (void) controller;
    (void) keycode;

    if ((state & (GDK_CONTROL_MASK | GDK_ALT_MASK)) != 0)
        return FALSE;

    /* Number keys pick from the list while it is on screen; off screen they are
     * ordinary digits and transliterate to Bangla numerals through the entry. */
    const gint index = byk_candidate_index (keyval);
    if (index >= 0 && self->shown != NULL &&
        (guint) index < g_strv_length (self->shown)) {
        byk_typing_page_commit (self, self->shown[index], NULL);
        return TRUE;
    }

    switch (keyval) {
    case GDK_KEY_space:
    case GDK_KEY_KP_Space: {
        gchar *bangla = byk_typing_page_bangla (self);
        byk_typing_page_commit (self, bangla, " ");
        g_free (bangla);
        return TRUE;
    }
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
    case GDK_KEY_ISO_Enter: {
        gchar *bangla = byk_typing_page_bangla (self);
        byk_typing_page_commit (self, bangla, "\n");
        g_free (bangla);
        return TRUE;
    }
    case GDK_KEY_Escape:
        /* Drops the word and the list together, like the engine's Escape. */
        gtk_editable_set_text (GTK_EDITABLE (self->entry), "");
        return TRUE;
    default:
        return FALSE;
    }
}

/* ── output actions ──────────────────────────────────────────────────────── */

static gchar *
byk_typing_page_text (BykTypingPage *self)
{
    GtkTextBuffer *buffer = gtk_text_view_get_buffer (GTK_TEXT_VIEW (self->output));
    GtkTextIter start, end;

    gtk_text_buffer_get_bounds (buffer, &start, &end);
    return gtk_text_buffer_get_text (buffer, &start, &end, FALSE);
}

static void
on_copy_clicked (GtkButton *button, gpointer user_data)
{
    BykTypingPage *self = BYK_TYPING_PAGE (user_data);
    (void) button;

    gchar *text = byk_typing_page_text (self);
    if (*text != '\0') {
        gdk_clipboard_set_text (gtk_widget_get_clipboard (GTK_WIDGET (self)), text);
        adw_toast_overlay_add_toast (self->toasts, adw_toast_new ("Copied to clipboard"));
    }
    g_free (text);
}

static void
on_clear_clicked (GtkButton *button, gpointer user_data)
{
    BykTypingPage *self = BYK_TYPING_PAGE (user_data);
    (void) button;

    gtk_text_buffer_set_text (gtk_text_view_get_buffer (GTK_TEXT_VIEW (self->output)), "", -1);
    gtk_editable_set_text (GTK_EDITABLE (self->entry), "");
    gtk_widget_grab_focus (self->entry);
}

static void
on_output_changed (GtkTextBuffer *buffer, gpointer user_data)
{
    BykTypingPage *self = BYK_TYPING_PAGE (user_data);
    const gint chars = gtk_text_buffer_get_char_count (buffer);

    /* Characters, not bytes: a Bangla word is 3 bytes per code point and a
     * byte count would just look wrong. */
    gchar *label = g_strdup_printf (chars == 1 ? "%d character" : "%d characters", chars);
    gtk_label_set_text (GTK_LABEL (self->counter), label);
    g_free (label);
}

/* ── construction ────────────────────────────────────────────────────────── */

/* A titled, framed area — the same shape as a libadwaita boxed list, used for
 * both the composer and the output so they read as one form. */
static GtkWidget *
byk_titled_group (const gchar *title, GtkWidget *content)
{
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
    GtkWidget *label = gtk_label_new (title);

    gtk_widget_add_css_class (label, "heading");
    gtk_widget_set_halign (label, GTK_ALIGN_START);
    gtk_box_append (GTK_BOX (box), label);
    gtk_box_append (GTK_BOX (box), content);

    return box;
}

static GtkWidget *
byk_typing_page_build_composer (BykTypingPage *self)
{
    GtkWidget *frame = gtk_frame_new (NULL);
    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

    gtk_widget_add_css_class (frame, "view");

    self->entry = gtk_entry_new ();
    gtk_entry_set_placeholder_text (GTK_ENTRY (self->entry),
                                    "Type \u201cami\u201d, then press Space");
    gtk_entry_set_has_frame (GTK_ENTRY (self->entry), FALSE);
    gtk_widget_add_css_class (self->entry, "byk-latin");
    g_signal_connect (self->entry, "changed", G_CALLBACK (on_entry_changed), self);

    GtkEventController *keys = gtk_event_controller_key_new ();
    /* Capture phase: GtkEntry would otherwise insert the space or the digit
     * before we get to interpret it. */
    gtk_event_controller_set_propagation_phase (keys, GTK_PHASE_CAPTURE);
    g_signal_connect (keys, "key-pressed", G_CALLBACK (on_entry_key_pressed), self);
    gtk_widget_add_controller (self->entry, keys);

    self->preedit = gtk_label_new ("\u200b");
    gtk_widget_add_css_class (self->preedit, "byk-preedit");
    gtk_label_set_xalign (GTK_LABEL (self->preedit), 0.0);
    gtk_label_set_ellipsize (GTK_LABEL (self->preedit), PANGO_ELLIPSIZE_END);
    gtk_label_set_selectable (GTK_LABEL (self->preedit), TRUE);

    self->candidates = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class (self->candidates, "byk-candidates");
    gtk_widget_set_visible (self->candidates, FALSE);

    GtkWidget *scroller = gtk_scrolled_window_new ();
    gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                    GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), self->candidates);

    gtk_box_append (GTK_BOX (box), self->entry);
    gtk_box_append (GTK_BOX (box), gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append (GTK_BOX (box), self->preedit);
    gtk_box_append (GTK_BOX (box), scroller);
    gtk_frame_set_child (GTK_FRAME (frame), box);

    return frame;
}

static GtkWidget *
byk_typing_page_build_output (BykTypingPage *self)
{
    self->output = gtk_text_view_new ();
    gtk_text_view_set_wrap_mode (GTK_TEXT_VIEW (self->output), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_top_margin (GTK_TEXT_VIEW (self->output), 8);
    gtk_text_view_set_bottom_margin (GTK_TEXT_VIEW (self->output), 8);
    gtk_text_view_set_left_margin (GTK_TEXT_VIEW (self->output), 8);
    gtk_text_view_set_right_margin (GTK_TEXT_VIEW (self->output), 8);
    gtk_widget_add_css_class (self->output, "byk-bangla");

    g_signal_connect (gtk_text_view_get_buffer (GTK_TEXT_VIEW (self->output)),
                      "changed", G_CALLBACK (on_output_changed), self);

    GtkWidget *scroller = gtk_scrolled_window_new ();
    gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                    GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), self->output);
    gtk_widget_set_vexpand (scroller, TRUE);
    gtk_widget_add_css_class (scroller, "card");

    return scroller;
}

static GtkWidget *
byk_typing_page_build_actions (BykTypingPage *self)
{
    GtkWidget *bar = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);

    self->counter = gtk_label_new ("0 characters");
    gtk_widget_add_css_class (self->counter, "dim-label");
    gtk_widget_add_css_class (self->counter, "caption");
    gtk_widget_set_hexpand (self->counter, TRUE);
    gtk_widget_set_halign (self->counter, GTK_ALIGN_START);

    GtkWidget *copy = gtk_button_new_from_icon_name ("edit-copy-symbolic");
    gtk_widget_set_tooltip_text (copy, "Copy the text to the clipboard");
    g_signal_connect (copy, "clicked", G_CALLBACK (on_copy_clicked), self);

    GtkWidget *clear = gtk_button_new_from_icon_name ("edit-clear-all-symbolic");
    gtk_widget_set_tooltip_text (clear, "Clear the text");
    g_signal_connect (clear, "clicked", G_CALLBACK (on_clear_clicked), self);

    gtk_box_append (GTK_BOX (bar), self->counter);
    gtk_box_append (GTK_BOX (bar), copy);
    gtk_box_append (GTK_BOX (bar), clear);

    return bar;
}

static void
byk_typing_page_init (BykTypingPage *self)
{
    (void) self;
}

static void
byk_typing_page_dispose (GObject *object)
{
    BykTypingPage *self = BYK_TYPING_PAGE (object);

    g_clear_pointer (&self->shown, g_strfreev);

    G_OBJECT_CLASS (byk_typing_page_parent_class)->dispose (object);
}

static void
byk_typing_page_class_init (BykTypingPageClass *klass)
{
    G_OBJECT_CLASS (klass)->dispose = byk_typing_page_dispose;
}

GtkWidget *
byk_typing_page_new (BykEngines *engines)
{
    g_return_val_if_fail (engines != NULL, NULL);

    BykTypingPage *self = g_object_new (BYK_TYPE_TYPING_PAGE, NULL);
    self->engines = engines;

    GtkWidget *hint = gtk_label_new (
        "Composes with the same engine as the keyboard, so you can try Bangla "
        "here before adding the input source.");
    gtk_widget_add_css_class (hint, "dim-label");
    gtk_label_set_wrap (GTK_LABEL (hint), TRUE);
    gtk_label_set_xalign (GTK_LABEL (hint), 0.0);

    GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 18);
    gtk_box_append (GTK_BOX (column), hint);
    gtk_box_append (GTK_BOX (column),
                    byk_titled_group ("Compose", byk_typing_page_build_composer (self)));
    gtk_box_append (GTK_BOX (column),
                    byk_titled_group ("Text", byk_typing_page_build_output (self)));
    gtk_box_append (GTK_BOX (column), byk_typing_page_build_actions (self));

    GtkWidget *clamp = adw_clamp_new ();
    adw_clamp_set_maximum_size (ADW_CLAMP (clamp), 640);
    adw_clamp_set_child (ADW_CLAMP (clamp), column);
    gtk_widget_set_margin_top (clamp, 18);
    gtk_widget_set_margin_bottom (clamp, 18);
    gtk_widget_set_margin_start (clamp, 18);
    gtk_widget_set_margin_end (clamp, 18);

    GtkWidget *scroller = gtk_scrolled_window_new ();
    gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                    GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), clamp);

    self->toasts = ADW_TOAST_OVERLAY (adw_toast_overlay_new ());
    adw_toast_overlay_set_child (self->toasts, scroller);
    adw_bin_set_child (ADW_BIN (self), GTK_WIDGET (self->toasts));

    return GTK_WIDGET (self);
}
