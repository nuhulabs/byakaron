#include "spelling.h"

#include "uiutil.h"

/* Coalesce keystrokes into one pass, the same 250ms the macOS app debounces. */
#define BYK_CHECK_DEBOUNCE_MS 250
#define BYK_SUGGEST_LIMIT     8

/* A misspelled span. Offsets are in characters, not bytes: GtkTextBuffer
 * counts that way and Bangla is three bytes per code point. */
typedef struct {
    gchar *word;
    gint start;
    gint end;
} BykIssue;

struct _BykSpellPage {
    GtkBox parent_instance;

    BykEngines *engines;

    GtkWidget *stack;    /* loading / missing / ready */
    GtkWidget *editor;
    GtkTextBuffer *buffer;
    GtkTextTag *squiggle;

    GtkWidget *issues_list;
    GtkWidget *issues_title;
    GtkWidget *issues_empty; /* shown instead of the list when there is nothing */
    GtkWidget *empty_icon;
    GtkWidget *empty_label;
    GtkWidget *split;
    GtkWidget *sidebar;

    GtkWidget *correction;   /* GtkRevealer around the bar */
    GtkWidget *correction_word;
    GtkWidget *correction_options;

    GtkWidget *status_words;
    GtkWidget *status_chars;
    GtkWidget *status_issues;

    GtkWidget *fix_all;
    GtkWidget *toast;

    GArray *found;          /* BykIssue, cleared each pass */
    GHashTable *ignored;    /* word -> itself; accepted for this session only */
    gint selected;          /* index into `found`, or -1 */

    guint check_source;
    /* Set while the page is rewriting the list or moving the caret, so the
     * selection and cursor handlers do not answer their own changes. */
    gboolean syncing;
};

G_DEFINE_TYPE (BykSpellPage, byk_spell_page, GTK_TYPE_BOX)

static void byk_spell_page_check (BykSpellPage *self);
static void byk_spell_page_select (BykSpellPage *self, gint index);

/* ── tokenising ──────────────────────────────────────────────────────────── */

/*
 * Whether a code point can be part of a Bangla word.
 *
 * Only the Bengali block is checked, so latin, punctuation and emoji are left
 * alone rather than reported as misspelled — the same rule the macOS and
 * Windows apps apply. Digits and the currency/fraction signs are excluded
 * because ২০২৪ is not a misspelling, and the zero-width joiners are included
 * because they sit *inside* conjuncts and would otherwise split a word in two.
 */
static gboolean
byk_is_word_char (gunichar c)
{
    if (c == 0x200C || c == 0x200D) /* ZWNJ, ZWJ */
        return TRUE;
    if (c < 0x0980 || c > 0x09FF)
        return FALSE;
    if (c >= 0x09E6 && c <= 0x09EF) /* ০-৯ */
        return FALSE;
    if (c >= 0x09F2 && c <= 0x09FB) /* ৳ and the fraction signs */
        return FALSE;
    if (c == 0x09FD) /* ৽ abbreviation sign */
        return FALSE;
    return TRUE;
}

/* ── issue bookkeeping ───────────────────────────────────────────────────── */

static void
byk_issue_clear (gpointer data)
{
    g_free (((BykIssue *) data)->word);
}

static const BykIssue *
byk_spell_page_issue (BykSpellPage *self, gint index)
{
    if (index < 0 || index >= (gint) self->found->len)
        return NULL;
    return &g_array_index (self->found, BykIssue, index);
}

/* Ranked corrections for an issue, or NULL. Caller frees with g_strfreev. */
static gchar **
byk_spell_page_suggest (BykSpellPage *self, const BykIssue *issue)
{
    if (self->engines->spell == NULL || issue == NULL)
        return NULL;

    /*
     * Plain suggest, not suggest_ctx. The context-aware variant ranks with
     * bigrams and trigrams, and the locally built spell.db has neither table
     * populated (they need a Wikipedia export that is not in the repo), so
     * passing neighbours would cost two extra queries per word for identical
     * output. Worth revisiting the day the n-grams land.
     */
    return byk_spell_suggest (self->engines->spell, issue->word, BYK_SUGGEST_LIMIT);
}

/* ── the check pass ──────────────────────────────────────────────────────── */

static void
byk_spell_page_update_status (BykSpellPage *self, gint words)
{
    const gint chars = gtk_text_buffer_get_char_count (self->buffer);
    const guint issues = self->found->len;

    gchar *label = g_strdup_printf (words == 1 ? "%d word" : "%d words", words);
    gtk_label_set_text (GTK_LABEL (self->status_words), label);
    g_free (label);

    label = g_strdup_printf (chars == 1 ? "%d character" : "%d characters", chars);
    gtk_label_set_text (GTK_LABEL (self->status_chars), label);
    g_free (label);

    if (issues == 0) {
        gtk_label_set_text (GTK_LABEL (self->status_issues), "No issues");
        byk_css_remove (self->status_issues, "warning");
        byk_css_add (self->status_issues, "success");
    } else {
        label = g_strdup_printf (issues == 1 ? "%u issue" : "%u issues", issues);
        gtk_label_set_text (GTK_LABEL (self->status_issues), label);
        g_free (label);
        byk_css_remove (self->status_issues, "success");
        byk_css_add (self->status_issues, "warning");
    }

    gtk_widget_set_sensitive (self->fix_all, issues > 0);
}

static void
byk_spell_page_fill_list (BykSpellPage *self)
{
    byk_container_clear (self->issues_list);

    for (guint i = 0; i < self->found->len; i++) {
        const BykIssue *issue = &g_array_index (self->found, BykIssue, i);

        GtkWidget *label = gtk_label_new (issue->word);
        gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_MIDDLE);
        gtk_label_set_xalign (GTK_LABEL (label), 0.0);
        gtk_widget_set_hexpand (label, TRUE);

        GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
        gtk_widget_set_margin_top (box, 8);
        gtk_widget_set_margin_bottom (box, 8);
        gtk_widget_set_margin_start (box, 12);
        gtk_widget_set_margin_end (box, 12);
        byk_box_add_expand (box, label);

        GtkWidget *listrow = gtk_list_box_row_new ();
        gtk_container_add (GTK_CONTAINER (listrow), box);
        g_object_set_data (G_OBJECT (listrow), "byk-index", GINT_TO_POINTER ((gint) i));
        gtk_list_box_insert (GTK_LIST_BOX (self->issues_list), listrow, -1);
    }

    const gboolean any = self->found->len > 0;
    if (any)
        gtk_widget_show_all (self->issues_list);
    else
        gtk_widget_hide (self->issues_list);
    gtk_widget_set_visible (self->issues_empty, !any);

    if (any) {
        gchar *title = g_strdup_printf ("Issues (%u)", self->found->len);
        gtk_label_set_text (GTK_LABEL (self->issues_title), title);
        g_free (title);
    } else {
        gtk_label_set_text (GTK_LABEL (self->issues_title), "Issues");
    }

    /* Empty text and clean text are different kinds of nothing, and saying so
     * is the difference between "it works" and "it did not run". */
    if (!any) {
        const gboolean empty = gtk_text_buffer_get_char_count (self->buffer) == 0;
        gtk_image_set_from_icon_name (GTK_IMAGE (self->empty_icon),
                                      empty ? "document-edit-symbolic"
                                            : "emblem-ok-symbolic",
                                      GTK_ICON_SIZE_DND);
        gtk_label_set_text (GTK_LABEL (self->empty_label),
                            empty ? "Nothing to check yet" : "No misspellings");
    }
}

/* Walk the buffer, collect words the engine rejects, underline them. */
static void
byk_spell_page_check (BykSpellPage *self)
{
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds (self->buffer, &start, &end);

    gtk_text_buffer_remove_tag (self->buffer, self->squiggle, &start, &end);
    g_array_set_size (self->found, 0);

    gchar *text = gtk_text_buffer_get_text (self->buffer, &start, &end, FALSE);
    gint words = 0;

    if (self->engines->spell != NULL) {
        const gchar *p = text;
        gint offset = 0;

        while (*p != '\0') {
            const gunichar c = g_utf8_get_char (p);

            if (!byk_is_word_char (c)) {
                p = g_utf8_next_char (p);
                offset++;
                continue;
            }

            const gchar *word_start = p;
            const gint start_offset = offset;
            while (*p != '\0' && byk_is_word_char (g_utf8_get_char (p))) {
                p = g_utf8_next_char (p);
                offset++;
            }

            words++;
            gchar *word = g_strndup (word_start, (gsize) (p - word_start));

            if (!g_hash_table_contains (self->ignored, word) &&
                byk_spell_is_correct (self->engines->spell, word) == 0) {
                BykIssue issue = { .word = word, .start = start_offset, .end = offset };
                g_array_append_val (self->found, issue);

                GtkTextIter from, to;
                gtk_text_buffer_get_iter_at_offset (self->buffer, &from, start_offset);
                gtk_text_buffer_get_iter_at_offset (self->buffer, &to, offset);
                gtk_text_buffer_apply_tag (self->buffer, self->squiggle, &from, &to);
            } else {
                g_free (word);
            }
        }
    }

    g_free (text);

    self->syncing = TRUE;
    byk_spell_page_fill_list (self);
    self->syncing = FALSE;

    byk_spell_page_update_status (self, words);

    /* The list was rebuilt, so whatever was selected no longer refers to
     * anything. Closing the bar is honest; re-guessing would not be. */
    byk_spell_page_select (self, -1);
}

static gboolean
on_check_timeout (gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);

    self->check_source = 0;
    byk_spell_page_check (self);
    return G_SOURCE_REMOVE;
}

static void
byk_spell_page_schedule_check (BykSpellPage *self)
{
    g_clear_handle_id (&self->check_source, g_source_remove);
    self->check_source = g_timeout_add (BYK_CHECK_DEBOUNCE_MS, on_check_timeout, self);
}

/* Re-check now, cancelling any pending debounce — used after apply / ignore so
 * the list is right before the selection moves on. */
static void
byk_spell_page_check_now (BykSpellPage *self)
{
    g_clear_handle_id (&self->check_source, g_source_remove);
    byk_spell_page_check (self);
}

/* ── correction bar ──────────────────────────────────────────────────────── */

static void on_suggestion_clicked (GtkButton *button, gpointer user_data);
static void on_ignore_clicked (GtkButton *button, gpointer user_data);

static void
byk_spell_page_build_correction (BykSpellPage *self, const BykIssue *issue)
{
    byk_container_clear (self->correction_options);

    gtk_label_set_text (GTK_LABEL (self->correction_word), issue->word);

    gchar **words = byk_spell_page_suggest (self, issue);

    if (words == NULL || words[0] == NULL) {
        GtkWidget *none = gtk_label_new ("No suggestions");
        byk_css_add (none, "dim-label");
        byk_box_add (self->correction_options, none);
    } else {
        for (guint i = 0; words[i] != NULL; i++) {
            GtkWidget *button = gtk_button_new_with_label (words[i]);
            byk_css_add (button, "byk-candidate");
            g_signal_connect (button, "clicked",
                              G_CALLBACK (on_suggestion_clicked), self);
            byk_box_add (self->correction_options, button);
        }
    }
    g_strfreev (words);
    gtk_widget_show_all (self->correction_options);
}

/* Select issue `index` (-1 for none): highlight it in the text and open the bar. */
static void
byk_spell_page_select (BykSpellPage *self, gint index)
{
    const BykIssue *issue = byk_spell_page_issue (self, index);

    self->selected = issue != NULL ? index : -1;

    if (issue == NULL) {
        gtk_revealer_set_reveal_child (GTK_REVEALER (self->correction), FALSE);
        self->syncing = TRUE;
        gtk_list_box_unselect_all (GTK_LIST_BOX (self->issues_list));
        self->syncing = FALSE;
        return;
    }

    byk_spell_page_build_correction (self, issue);
    gtk_revealer_set_reveal_child (GTK_REVEALER (self->correction), TRUE);

    const gboolean was_syncing = self->syncing;
    self->syncing = TRUE;

    GtkTextIter from, to;
    gtk_text_buffer_get_iter_at_offset (self->buffer, &from, issue->start);
    gtk_text_buffer_get_iter_at_offset (self->buffer, &to, issue->end);
    gtk_text_buffer_select_range (self->buffer, &from, &to);
    gtk_text_view_scroll_to_iter (GTK_TEXT_VIEW (self->editor), &from, 0.1, FALSE, 0.0, 0.0);

    GtkListBoxRow *row = gtk_list_box_get_row_at_index (GTK_LIST_BOX (self->issues_list), index);
    if (row != NULL)
        gtk_list_box_select_row (GTK_LIST_BOX (self->issues_list), row);

    self->syncing = was_syncing;
}

/*
 * Replace the span [start, end) with `replacement`, then re-check.
 *
 * Offsets rather than a BykIssue *: the re-check at the end empties `found`
 * and frees every word in it, so a caller holding an issue pointer across
 * this call would be holding freed memory.
 */
static void
byk_spell_page_apply (BykSpellPage *self, gint start, gint end, const gchar *replacement)
{
    GtkTextIter from, to;

    self->syncing = TRUE;
    gtk_text_buffer_get_iter_at_offset (self->buffer, &from, start);
    gtk_text_buffer_get_iter_at_offset (self->buffer, &to, end);
    gtk_text_buffer_begin_user_action (self->buffer);
    gtk_text_buffer_delete (self->buffer, &from, &to);
    gtk_text_buffer_insert (self->buffer, &from, replacement, -1);
    gtk_text_buffer_end_user_action (self->buffer);
    self->syncing = FALSE;

    byk_spell_page_check_now (self);
}

static void
on_suggestion_clicked (GtkButton *button, gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);
    const BykIssue *issue = byk_spell_page_issue (self, self->selected);

    if (issue == NULL)
        return;

    /* The bar is torn down by the re-check inside apply, so read the label and
     * the span before touching the buffer. */
    gchar *replacement = g_strdup (gtk_button_get_label (button));
    const gint start = issue->start;
    const gint end = issue->end;

    byk_spell_page_apply (self, start, end, replacement);
    g_free (replacement);
}

static void
on_ignore_clicked (GtkButton *button, gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);
    const BykIssue *issue = byk_spell_page_issue (self, self->selected);
    (void) button;

    if (issue == NULL)
        return;

    /* Session-only, like the macOS app: nothing is written back to spell.db,
     * so an accidental Ignore cannot poison the dictionary. */
    g_hash_table_add (self->ignored, g_strdup (issue->word));
    byk_spell_page_check_now (self);
}

/* ── toolbar actions ─────────────────────────────────────────────────────── */

static void
on_fix_all_clicked (GtkButton *button, gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);
    (void) button;

    if (self->found->len == 0)
        return;

    /*
     * Walk from the end of the text backwards. Replacements change the length
     * of the text, so fixing the first issue would invalidate every offset
     * after it; going backwards leaves the offsets still to be used untouched.
     */
    guint fixed = 0;
    self->syncing = TRUE;
    gtk_text_buffer_begin_user_action (self->buffer);

    for (gint i = (gint) self->found->len - 1; i >= 0; i--) {
        const BykIssue *issue = &g_array_index (self->found, BykIssue, i);
        gchar **words = byk_spell_page_suggest (self, issue);

        if (words != NULL && words[0] != NULL) {
            GtkTextIter from, to;
            gtk_text_buffer_get_iter_at_offset (self->buffer, &from, issue->start);
            gtk_text_buffer_get_iter_at_offset (self->buffer, &to, issue->end);
            gtk_text_buffer_delete (self->buffer, &from, &to);
            gtk_text_buffer_insert (self->buffer, &from, words[0], -1);
            fixed++;
        }
        g_strfreev (words);
    }

    gtk_text_buffer_end_user_action (self->buffer);
    self->syncing = FALSE;
    byk_spell_page_check_now (self);

    gchar *message = fixed == 0
        ? g_strdup ("Nothing to fix — no suggestions")
        : g_strdup_printf (fixed == 1 ? "Fixed 1 word" : "Fixed %u words", fixed);
    byk_toast_show (GTK_LABEL (self->toast), message);
    g_free (message);
}

static void
on_copy_clicked (GtkButton *button, gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);
    GtkTextIter start, end;
    (void) button;

    gtk_text_buffer_get_bounds (self->buffer, &start, &end);
    gchar *text = gtk_text_buffer_get_text (self->buffer, &start, &end, FALSE);

    if (*text != '\0') {
        byk_clipboard_set (GTK_WIDGET (self), text);
        byk_toast_show (GTK_LABEL (self->toast), "Copied to clipboard");
    }
    g_free (text);
}

static void
on_clear_clicked (GtkButton *button, gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);
    (void) button;

    gtk_text_buffer_set_text (self->buffer, "", -1);
    byk_spell_page_check_now (self);
}

static void
on_sidebar_toggled (GtkToggleButton *toggle, gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);
    gtk_widget_set_visible (self->sidebar, gtk_toggle_button_get_active (toggle));
}

/* ── signals ─────────────────────────────────────────────────────────────── */

static void
on_buffer_changed (GtkTextBuffer *buffer, gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);
    (void) buffer;

    if (!self->syncing)
        byk_spell_page_schedule_check (self);
}

static void
on_row_selected (GtkListBox *box, GtkListBoxRow *row, gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);
    (void) box;

    if (self->syncing || row == NULL)
        return;

    byk_spell_page_select (self,
                           GPOINTER_TO_INT (g_object_get_data (G_OBJECT (row), "byk-index")));
}

/*
 * Clicking a squiggle in the text selects that issue.
 *
 * Stands in for the macOS right-click menu: it reaches the same suggestions
 * through the correction bar without a menu that has to be rebuilt per click.
 */
static void
on_cursor_moved (GtkTextBuffer *buffer, GParamSpec *pspec, gpointer user_data)
{
    BykSpellPage *self = BYK_SPELL_PAGE (user_data);
    (void) pspec;

    if (self->syncing)
        return;

    GtkTextIter iter;
    gtk_text_buffer_get_iter_at_mark (buffer, &iter, gtk_text_buffer_get_insert (buffer));
    const gint cursor = gtk_text_iter_get_offset (&iter);

    for (guint i = 0; i < self->found->len; i++) {
        const BykIssue *issue = &g_array_index (self->found, BykIssue, i);
        if (cursor >= issue->start && cursor <= issue->end) {
            if (self->selected != (gint) i)
                byk_spell_page_select (self, (gint) i);
            return;
        }
    }
}

/* ── construction ────────────────────────────────────────────────────────── */

static GtkWidget *
byk_spell_page_build_sidebar (BykSpellPage *self)
{
    self->issues_title = gtk_label_new ("Issues");
    byk_css_add (self->issues_title, "heading");
    gtk_label_set_xalign (GTK_LABEL (self->issues_title), 0.0);
    gtk_widget_set_margin_top (self->issues_title, 12);
    gtk_widget_set_margin_bottom (self->issues_title, 6);
    gtk_widget_set_margin_start (self->issues_title, 12);
    gtk_widget_set_margin_end (self->issues_title, 12);

    self->issues_list = gtk_list_box_new ();
    gtk_list_box_set_selection_mode (GTK_LIST_BOX (self->issues_list), GTK_SELECTION_SINGLE);
    byk_css_add (self->issues_list, "navigation-sidebar");
    byk_hide_until_shown (self->issues_list);
    g_signal_connect (self->issues_list, "row-selected", G_CALLBACK (on_row_selected), self);

    self->empty_icon = gtk_image_new_from_icon_name ("document-edit-symbolic", GTK_ICON_SIZE_DND);
    gtk_image_set_pixel_size (GTK_IMAGE (self->empty_icon), 32);
    byk_css_add (self->empty_icon, "dim-label");

    self->empty_label = gtk_label_new ("Nothing to check yet");
    byk_css_add (self->empty_label, "dim-label");
    gtk_label_set_line_wrap (GTK_LABEL (self->empty_label), TRUE);
    gtk_label_set_justify (GTK_LABEL (self->empty_label), GTK_JUSTIFY_CENTER);

    self->issues_empty = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_valign (self->issues_empty, GTK_ALIGN_CENTER);
    gtk_widget_set_vexpand (self->issues_empty, TRUE);
    gtk_widget_set_margin_start (self->issues_empty, 18);
    gtk_widget_set_margin_end (self->issues_empty, 18);
    byk_box_add (self->issues_empty, self->empty_icon);
    byk_box_add (self->issues_empty, self->empty_label);

    GtkWidget *stack = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    byk_box_add (stack, self->issues_list);
    byk_box_add_expand (stack, self->issues_empty);

    GtkWidget *scroller = byk_scroller (stack, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand (scroller, TRUE);

    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    byk_box_add (box, self->issues_title);
    byk_box_add_expand (box, scroller);

    return box;
}

static GtkWidget *
byk_spell_page_build_toolbar (BykSpellPage *self)
{
    GtkWidget *bar = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top (bar, 6);
    gtk_widget_set_margin_bottom (bar, 6);
    gtk_widget_set_margin_start (bar, 12);
    gtk_widget_set_margin_end (bar, 12);

    GtkWidget *toggle = gtk_toggle_button_new ();
    gtk_button_set_image (GTK_BUTTON (toggle),
                          gtk_image_new_from_icon_name ("view-list-symbolic",
                                                        GTK_ICON_SIZE_BUTTON));
    gtk_widget_set_tooltip_text (toggle, "Show the issue list");
    gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON (toggle), TRUE);
    g_signal_connect (toggle, "toggled", G_CALLBACK (on_sidebar_toggled), self);

    GtkWidget *spacer = gtk_label_new (NULL);
    gtk_widget_set_hexpand (spacer, TRUE);

    self->fix_all = gtk_button_new_with_label ("Fix All");
    gtk_widget_set_tooltip_text (self->fix_all, "Replace every issue with its top suggestion");
    gtk_widget_set_sensitive (self->fix_all, FALSE);
    g_signal_connect (self->fix_all, "clicked", G_CALLBACK (on_fix_all_clicked), self);

    GtkWidget *copy = byk_icon_button ("edit-copy-symbolic");
    gtk_widget_set_tooltip_text (copy, "Copy the full text to the clipboard");
    g_signal_connect (copy, "clicked", G_CALLBACK (on_copy_clicked), self);

    GtkWidget *clear = byk_icon_button ("edit-clear-all-symbolic");
    gtk_widget_set_tooltip_text (clear, "Clear the editor");
    g_signal_connect (clear, "clicked", G_CALLBACK (on_clear_clicked), self);

    byk_box_add (bar, toggle);
    byk_box_add_expand (bar, spacer);
    byk_box_add (bar, self->fix_all);
    byk_box_add (bar, copy);
    byk_box_add (bar, clear);

    return bar;
}

static GtkWidget *
byk_spell_page_build_correction_bar (BykSpellPage *self)
{
    GtkWidget *bar = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top (bar, 8);
    gtk_widget_set_margin_bottom (bar, 8);
    gtk_widget_set_margin_start (bar, 12);
    gtk_widget_set_margin_end (bar, 12);

    self->correction_word = gtk_label_new (NULL);
    byk_css_add (self->correction_word, "heading");

    GtkWidget *arrow = gtk_label_new ("Replace with");
    byk_css_add (arrow, "dim-label");

    self->correction_options = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);

    GtkWidget *scroller = byk_scroller (self->correction_options,
                                        GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
    gtk_widget_set_hexpand (scroller, TRUE);

    /* Outside the scroller: with eight suggestions the strip overflows, and
     * Ignore is the one control that must not scroll out of reach. */
    GtkWidget *ignore = gtk_button_new_with_label ("Ignore");
    gtk_widget_set_tooltip_text (ignore, "Accept this word for now");
    g_signal_connect (ignore, "clicked", G_CALLBACK (on_ignore_clicked), self);

    byk_box_add (bar, self->correction_word);
    byk_box_add (bar, arrow);
    byk_box_add_expand (bar, scroller);
    byk_box_add (bar, ignore);

    self->correction = gtk_revealer_new ();
    gtk_revealer_set_transition_type (GTK_REVEALER (self->correction),
                                      GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP);
    gtk_container_add (GTK_CONTAINER (self->correction), bar);
    gtk_revealer_set_reveal_child (GTK_REVEALER (self->correction), FALSE);

    return self->correction;
}

static GtkWidget *
byk_spell_page_build_status_bar (BykSpellPage *self)
{
    GtkWidget *bar = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_top (bar, 6);
    gtk_widget_set_margin_bottom (bar, 6);
    gtk_widget_set_margin_start (bar, 12);
    gtk_widget_set_margin_end (bar, 12);

    self->status_words = gtk_label_new ("0 words");
    self->status_chars = gtk_label_new ("0 characters");
    self->status_issues = gtk_label_new ("No issues");

    byk_css_add (self->status_words, "caption");
    byk_css_add (self->status_words, "dim-label");
    byk_css_add (self->status_chars, "caption");
    byk_css_add (self->status_chars, "dim-label");
    byk_css_add (self->status_issues, "caption");
    byk_css_add (self->status_issues, "success");

    GtkWidget *spacer = gtk_label_new (NULL);
    gtk_widget_set_hexpand (spacer, TRUE);

    byk_box_add (bar, self->status_words);
    byk_box_add (bar, self->status_chars);
    byk_box_add_expand (bar, spacer);
    byk_box_add (bar, self->status_issues);

    return bar;
}

static GtkWidget *
byk_spell_page_build_editor (BykSpellPage *self)
{
    self->editor = gtk_text_view_new ();
    self->buffer = gtk_text_view_get_buffer (GTK_TEXT_VIEW (self->editor));

    gtk_text_view_set_wrap_mode (GTK_TEXT_VIEW (self->editor), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_top_margin (GTK_TEXT_VIEW (self->editor), 12);
    gtk_text_view_set_bottom_margin (GTK_TEXT_VIEW (self->editor), 12);
    gtk_text_view_set_left_margin (GTK_TEXT_VIEW (self->editor), 12);
    gtk_text_view_set_right_margin (GTK_TEXT_VIEW (self->editor), 12);
    byk_css_add (self->editor, "byk-bangla");

    /* PANGO_UNDERLINE_ERROR is the platform's own squiggle, so a misspelling
     * looks the same here as in any other GTK text view. */
    self->squiggle = gtk_text_buffer_create_tag (self->buffer, "misspelled",
                                                 "underline", PANGO_UNDERLINE_ERROR,
                                                 NULL);

    g_signal_connect (self->buffer, "changed", G_CALLBACK (on_buffer_changed), self);
    g_signal_connect (self->buffer, "notify::cursor-position",
                      G_CALLBACK (on_cursor_moved), self);

    GtkWidget *scroller = byk_scroller (self->editor, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand (scroller, TRUE);

    return scroller;
}

static GtkWidget *
byk_spell_page_build_ready (BykSpellPage *self)
{
    self->sidebar = byk_spell_page_build_sidebar (self);
    gtk_widget_set_size_request (self->sidebar, 220, -1);

    GtkWidget *content = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    byk_box_add (content, byk_spell_page_build_toolbar (self));
    byk_box_add_expand (content, byk_spell_page_build_editor (self));
    byk_box_add (content, byk_spell_page_build_correction_bar (self));
    byk_box_add (content, byk_spell_page_build_status_bar (self));

    self->toast = gtk_label_new ("");
    byk_css_add (self->toast, "byk-toast");
    byk_css_add (self->toast, "dim-label");
    byk_hide_until_shown (self->toast);
    byk_box_add (content, self->toast);

    self->split = gtk_paned_new (GTK_ORIENTATION_HORIZONTAL);
    gtk_paned_pack1 (GTK_PANED (self->split), self->sidebar, FALSE, FALSE);
    gtk_paned_pack2 (GTK_PANED (self->split), content, TRUE, FALSE);
    gtk_paned_set_position (GTK_PANED (self->split), 240);

    return self->split;
}

static GtkWidget *
byk_spell_page_build_loading (void)
{
    GtkWidget *spinner = gtk_spinner_new ();
    gtk_spinner_start (GTK_SPINNER (spinner));
    gtk_widget_set_size_request (spinner, 32, 32);
    gtk_widget_set_halign (spinner, GTK_ALIGN_CENTER);

    GtkWidget *page = byk_status_page (NULL,
                                       "Loading dictionary\u2026",
                                       "Opening spell.db. This happens once per launch.");
    byk_box_add (page, spinner);
    return page;
}

static GtkWidget *
byk_spell_page_build_missing (void)
{
    return byk_status_page (
        "dialog-warning-symbolic",
        "Dictionary unavailable",
        "spell.db is not installed, so spelling cannot be checked. Typing Bangla "
        "still works — the keyboard and its candidate list do not need it.\n\n"
        "Build it with platforms/linux/scripts/prepare_spell_db.sh, or "
        "install the .deb, which ships it.");
}

static void
byk_spell_page_init (BykSpellPage *self)
{
    gtk_orientable_set_orientation (GTK_ORIENTABLE (self), GTK_ORIENTATION_VERTICAL);
    self->found = g_array_new (FALSE, FALSE, sizeof (BykIssue));
    g_array_set_clear_func (self->found, byk_issue_clear);
    self->ignored = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
    self->selected = -1;
}

static void
byk_spell_page_dispose (GObject *object)
{
    BykSpellPage *self = BYK_SPELL_PAGE (object);

    g_clear_handle_id (&self->check_source, g_source_remove);
    g_clear_pointer (&self->found, g_array_unref);
    g_clear_pointer (&self->ignored, g_hash_table_unref);

    G_OBJECT_CLASS (byk_spell_page_parent_class)->dispose (object);
}

static void
byk_spell_page_class_init (BykSpellPageClass *klass)
{
    G_OBJECT_CLASS (klass)->dispose = byk_spell_page_dispose;
}

GtkWidget *
byk_spell_page_new (BykEngines *engines)
{
    g_return_val_if_fail (engines != NULL, NULL);

    BykSpellPage *self = g_object_new (BYK_TYPE_SPELL_PAGE, NULL);
    self->engines = engines;

    self->stack = gtk_stack_new ();
    gtk_stack_add_named (GTK_STACK (self->stack), byk_spell_page_build_loading (), "loading");
    gtk_stack_add_named (GTK_STACK (self->stack), byk_spell_page_build_missing (), "missing");
    gtk_stack_add_named (GTK_STACK (self->stack), byk_spell_page_build_ready (self), "ready");
    gtk_stack_set_visible_child_name (GTK_STACK (self->stack), "loading");

    byk_box_add_expand (GTK_WIDGET (self), self->stack);

    return GTK_WIDGET (self);
}

void
byk_spell_page_engine_ready (BykSpellPage *self)
{
    g_return_if_fail (BYK_IS_SPELL_PAGE (self));

    if (self->engines->spell == NULL) {
        gtk_stack_set_visible_child_name (GTK_STACK (self->stack), "missing");
        return;
    }

    gtk_stack_set_visible_child_name (GTK_STACK (self->stack), "ready");
    byk_spell_page_check_now (self);
}
