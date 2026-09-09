#include "typing.h"

#include "composer.h"
#include "prefs.h"

struct _BykTypingPage {
    AdwBin parent_instance;

    BykComposer *composer;
    GSettings *prefs; /* NULL when the schema is not installed */

    GtkWidget *entry;      /* latin for the word being composed */
    GtkWidget *preedit;    /* its Bangla, updated on every keystroke */
    GtkWidget *candidates; /* GtkBox of buttons, one per completion */
    GtkWidget *output;     /* GtkTextView holding what has been committed */
    GtkWidget *counter;

    AdwToastOverlay *toasts;
};

G_DEFINE_FINAL_TYPE (BykTypingPage, byk_typing_page, ADW_TYPE_BIN)

static void byk_typing_page_sync (BykTypingPage *self);

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

/* ── candidates ──────────────────────────────────────────────────────────── */

static void
on_candidate_clicked (GtkButton *button, gpointer user_data)
{
    BykTypingPage *self = BYK_TYPING_PAGE (user_data);
    const guint index = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (button), "index"));
    BykOutcome outcome = byk_composer_select (self->composer, index);

    if (outcome.action == BYK_ACT_COMMIT &&
        outcome.commit != NULL && outcome.commit[0] != '\0')
        byk_typing_page_append (self, outcome.commit);
    g_free (outcome.commit);
    byk_typing_page_sync (self);
}

static void
byk_typing_page_clear_candidates (BykTypingPage *self)
{
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child (self->candidates)) != NULL)
        gtk_box_remove (GTK_BOX (self->candidates), child);

    gtk_widget_set_visible (self->candidates, FALSE);
}

static void
byk_typing_page_show_candidates (BykTypingPage *self)
{
    byk_typing_page_clear_candidates (self);

    gchar **words = byk_composer_candidates (self->composer);
    if (words == NULL || words[0] == NULL)
        return;

    const guint start = byk_composer_page (self->composer) * BYK_COMPOSER_PAGE_SIZE;
    for (guint i = 0; i < BYK_COMPOSER_PAGE_SIZE; i++) {
        if (words[start + i] == NULL)
            break;

        GtkWidget *button = gtk_button_new_with_label (words[start + i]);
        gchar *tooltip = g_strdup_printf ("Press %u to insert %s",
                                          i + 1, words[start + i]);
        gtk_widget_set_tooltip_text (button, tooltip);
        g_free (tooltip);

        gtk_widget_add_css_class (button, "byk-candidate");
        g_object_set_data (G_OBJECT (button), "index", GUINT_TO_POINTER (i));
        g_signal_connect (button, "clicked", G_CALLBACK (on_candidate_clicked), self);
        gtk_box_append (GTK_BOX (self->candidates), button);
    }

    gtk_widget_set_visible (self->candidates, TRUE);
}

/* ── live transliteration (composer is the source of truth) ──────────────── */

static void
byk_typing_page_sync (BykTypingPage *self)
{
    const gchar *latin = byk_composer_latin (self->composer);
    gtk_editable_set_text (GTK_EDITABLE (self->entry), latin != NULL ? latin : "");

    gchar *bangla = byk_composer_preedit (self->composer);
    if (bangla == NULL || *bangla == '\0') {
        /* Keep the row's height so the layout does not jump on every word. */
        gtk_label_set_text (GTK_LABEL (self->preedit), "\u200b");
        gtk_widget_remove_css_class (self->preedit, "byk-preedit-filled");
    } else {
        gtk_label_set_text (GTK_LABEL (self->preedit), bangla);
        gtk_widget_add_css_class (self->preedit, "byk-preedit-filled");
    }
    g_free (bangla);

    byk_typing_page_show_candidates (self);
}

static void
byk_typing_page_apply_prefs (BykTypingPage *self)
{
    byk_composer_set_phonetic_only (
        self->composer,
        byk_prefs_boolean (self->prefs, BYK_PREFS_PHONETIC_ONLY, FALSE));
    byk_typing_page_sync (self);
}

static void
on_prefs_changed (GSettings *settings, gchar *key, gpointer user_data)
{
    (void) settings;
    (void) key;
    byk_typing_page_apply_prefs (BYK_TYPING_PAGE (user_data));
}

/* ── key handling (the same Core/composer.c IBus and Fcitx5 use) ─────────── */

static guint
byk_gdk_mods (GdkModifierType state)
{
    guint mods = 0;
    if (state & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK | GDK_META_MASK))
        mods |= BYK_MOD_SHORTCUT;
    return mods;
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

    if (keyval == GDK_KEY_ISO_Enter)
        keyval = GDK_KEY_Return;

    BykOutcome outcome = byk_composer_key (self->composer, keyval, byk_gdk_mods (state));

    switch (outcome.action) {
    case BYK_ACT_PASS:
        g_free (outcome.commit);
        /* Empty buffer: Space and Enter are still real keystrokes in the pad. */
        if (keyval == GDK_KEY_space || keyval == GDK_KEY_KP_Space) {
            byk_typing_page_append (self, " ");
            return TRUE;
        }
        if (keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter) {
            byk_typing_page_append (self, "\n");
            return TRUE;
        }
        return FALSE;

    case BYK_ACT_EAT:
        byk_typing_page_sync (self);
        g_free (outcome.commit);
        return TRUE;

    case BYK_ACT_COMMIT:
        if (outcome.commit != NULL && outcome.commit[0] != '\0')
            byk_typing_page_append (self, outcome.commit);
        /* Enter commits then is a newline here (the IME would pass it to the
         * application; this page *is* the application). */
        if (outcome.pass_key &&
            (keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter))
            byk_typing_page_append (self, "\n");
        byk_typing_page_sync (self);
        g_free (outcome.commit);
        return outcome.pass_key &&
               keyval != GDK_KEY_Return && keyval != GDK_KEY_KP_Enter
                   ? FALSE
                   : TRUE;
    }

    g_free (outcome.commit);
    return FALSE;
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
    {
        BykOutcome outcome = byk_composer_key (self->composer, GDK_KEY_Escape, 0);
        g_free (outcome.commit);
    }
    byk_typing_page_sync (self);
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

    GtkEventController *keys = gtk_event_controller_key_new ();
    /* Capture phase: GtkEntry would otherwise insert the space, digit, or
     * punctuation before the composer sees it. */
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

    g_clear_pointer (&self->composer, byk_composer_free);
    g_clear_object (&self->prefs);

    G_OBJECT_CLASS (byk_typing_page_parent_class)->dispose (object);
}

static void
byk_typing_page_class_init (BykTypingPageClass *klass)
{
    G_OBJECT_CLASS (klass)->dispose = byk_typing_page_dispose;
}

GtkWidget *
byk_typing_page_new (void)
{
    BykTypingPage *self = g_object_new (BYK_TYPE_TYPING_PAGE, NULL);

    self->composer = byk_composer_new ();
    self->prefs = byk_prefs_try_open ();
    if (self->prefs != NULL)
        g_signal_connect (self->prefs, "changed::" BYK_PREFS_PHONETIC_ONLY,
                          G_CALLBACK (on_prefs_changed), self);

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

    byk_typing_page_apply_prefs (self);

    return GTK_WIDGET (self);
}
