#include "layout.h"

#include "uiutil.h"

typedef struct {
    const gchar *bangla;
    const gchar *keys;
} BykLayoutEntry;

typedef struct {
    const gchar *title;
    const BykLayoutEntry *entries;
    gsize count;
} BykLayoutSection;

/*
 * Varga order, five to a row, the way the alphabet is taught — the flow box
 * shows up to five per line, so a wide window reads ক খ গ ঘ ঙ across. Every
 * key here was run through the engine; keep it that way when editing.
 */
static const BykLayoutEntry CONSONANTS[] = {
    { "ক", "k" },     { "খ", "kh" },     { "গ", "g" },   { "ঘ", "gh" },  { "ঙ", "Ng" },
    { "চ", "c" },     { "ছ", "ch" },     { "জ", "j" },   { "ঝ", "jh" },  { "ঞ", "NG" },
    { "ট", "T" },     { "ঠ", "Th" },     { "ড", "D" },   { "ঢ", "Dh" },  { "ণ", "N" },
    { "ত", "t" },     { "থ", "th" },     { "দ", "d" },   { "ধ", "dh" },  { "ন", "n" },
    { "প", "p" },     { "ফ", "ph, f" },  { "ব", "b" },   { "ভ", "bh, v" }, { "ম", "m" },
    { "য", "z" },     { "র", "r" },      { "ল", "l" },   { "শ", "sh, S" }, { "ষ", "Sh" },
    { "স", "s" },     { "হ", "h" },      { "ড়", "R" },   { "ঢ়", "Rh" },  { "য়", "y, Y" },
    { "ৎ", "t``" },   { "ং", "ng" },     { "ঃ", ":" },   { "ঁ", "^" },
};

static const BykLayoutEntry VOWELS[] = {
    { "অ", "o" },        { "আ / কা", "a" },  { "ই / কি", "i" },  { "ঈ / কী", "I" },
    { "উ / কু", "u" },   { "ঊ / কূ", "U" },  { "ঋ / কৃ", "rri" }, { "এ / কে", "e" },
    { "ঐ / কৈ", "OI" },  { "ও / কো", "O" },  { "ঔ / কৌ", "OU" },
};

/* Shown as an example rather than a bare mark, so the key is unambiguous. */
static const BykLayoutEntry SPECIAL[] = {
    { "ক্য য-ফলা", "ky, kZ" },  { "ক্র র-ফলা", "kr" },   { "ক্ব ব-ফলা", "kw" },
    { "র্ক রেফ", "rrk" },       { "ক্‌ হসন্ত", "k,," },  { "কক, ক্ক নয়", "k`k" },
    { "। দাড়ি", "." },         { "৳ টাকা", "$" },
};

static const BykLayoutEntry NUMBERS[] = {
    { "০", "0" }, { "১", "1" }, { "২", "2" }, { "৩", "3" }, { "৪", "4" },
    { "৫", "5" }, { "৬", "6" }, { "৭", "7" }, { "৮", "8" }, { "৯", "9" },
};

#define BYK_SECTION(title_, array_) \
    { (title_), (array_), G_N_ELEMENTS (array_) }

static const BykLayoutSection SECTIONS[] = {
    BYK_SECTION ("Consonants (ব্যঞ্জনবর্ণ)", CONSONANTS),
    BYK_SECTION ("Vowels (স্বরবর্ণ)", VOWELS),
    BYK_SECTION ("Special", SPECIAL),
    BYK_SECTION ("Numbers (সংখ্যা)", NUMBERS),
};

/* `glyphs` sizes every Bangla label in a section alike, so the keys line up in
 * a column even when one entry (আ / কা, ক্য য-ফলা) is wider than the rest. */
static GtkWidget *
byk_layout_cell (const BykLayoutEntry *entry, GtkSizeGroup *glyphs)
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

static GtkWidget *
byk_layout_group (const BykLayoutSection *section)
{
    GtkWidget *box = byk_section (section->title, NULL);

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
    for (gsize i = 0; i < section->count; i++)
        gtk_container_add (GTK_CONTAINER (flow),
                           byk_layout_cell (&section->entries[i], glyphs));
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

    GtkWidget *intro = byk_section (
        NULL,
        "Byakaron types Avro Phonetic. Capital letters are their own keys, not "
        "shifted versions of the lowercase ones — T is ট, not ত.");
    byk_box_add (column, intro);

    for (gsize i = 0; i < G_N_ELEMENTS (SECTIONS); i++)
        byk_box_add (column, byk_layout_group (&SECTIONS[i]));

    return byk_scroller (column, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
}
