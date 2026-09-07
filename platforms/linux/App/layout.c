#include "layout.h"

typedef struct {
    const gchar *bangla;
    const gchar *keys;
} BykLayoutEntry;

typedef struct {
    const gchar *title;
    const BykLayoutEntry *entries;
    gsize count;
} BykLayoutSection;

static const BykLayoutEntry CONSONANTS[] = {
    { "ক", "k" },   { "ট", "T" },  { "প", "p" },      { "স", "s" },
    { "খ", "kh" },  { "ঠ", "Th" }, { "ফ", "ph, f" },  { "হ", "h" },
    { "গ", "g" },   { "ড", "D" },  { "ব", "b" },      { "ড়", "R" },
    { "ঘ", "gh" },  { "ঢ", "Dh" }, { "ভ", "bh, v" },  { "ঢ়", "Rh" },
    { "ঙ", "Ng" },  { "ণ", "N" },  { "ম", "m" },      { "য়", "y, Y" },
    { "চ", "c" },   { "ত", "t" },  { "য", "z" },      { "শ", "sh, S" },
    { "ছ", "ch" },  { "থ", "th" }, { "র", "r" },      { "ষ", "Sh" },
    { "জ", "j" },   { "দ", "d" },  { "ল", "l" },      { "ং", "ng" },
    { "ঝ", "jh" },  { "ধ", "dh" }, { "ঃ", ":" },      { "ঁ", "^" },
    { "ঞ", "NG" },  { "ন", "n" },  { "ৎ", "t``" },
};

static const BykLayoutEntry VOWELS[] = {
    { "অ", "o" },        { "ই / কি", "i" },  { "উ / কু", "u" },
    { "আ / কা", "a" },   { "ঈ / কী", "I" },  { "ঊ / কূ", "U" },
    { "ঋ / কৃ", "rri" }, { "এ / কে", "e" },  { "ও / কো", "O" },
    { "ঐ / কৈ", "OI" },  { "ঔ / কৌ", "OU" },
};

static const BykLayoutEntry SPECIAL[] = {
    { "্ হসন্ত", ",," },  { "ব-ফলা", "w" },    { "রেফ", "rr (v)" },
    { "় নুক্তা", ".." }, { "য-ফলা", "y, Z" }, { "। দাড়ি", "." },
    { "ZWJ", "`" },       { "র-ফলা", "r" },    { "৳ টাকা", "$" },
    { "ZWNJ", "~" },
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

static GtkWidget *
byk_layout_cell (const BykLayoutEntry *entry)
{
    GtkWidget *bangla = gtk_label_new (entry->bangla);
    gtk_label_set_xalign (GTK_LABEL (bangla), 0.0);
    gtk_widget_set_size_request (bangla, 64, -1);
    gtk_widget_add_css_class (bangla, "byk-layout-glyph");

    GtkWidget *keys = gtk_label_new (entry->keys);
    gtk_label_set_xalign (GTK_LABEL (keys), 0.0);
    gtk_widget_add_css_class (keys, "monospace");
    gtk_widget_add_css_class (keys, "dim-label");
    gtk_widget_set_hexpand (keys, TRUE);

    GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append (GTK_BOX (box), bangla);
    gtk_box_append (GTK_BOX (box), keys);
    gtk_widget_set_margin_top (box, 4);
    gtk_widget_set_margin_bottom (box, 4);

    return box;
}

static GtkWidget *
byk_layout_group (const BykLayoutSection *section)
{
    GtkWidget *group = adw_preferences_group_new ();
    adw_preferences_group_set_title (ADW_PREFERENCES_GROUP (group), section->title);

    /* A flow box rather than a fixed grid: the macOS version uses an adaptive
     * grid, and the same number of columns cannot suit both a 40-entry
     * consonant table and a 10-entry number row. */
    GtkWidget *flow = gtk_flow_box_new ();
    gtk_flow_box_set_selection_mode (GTK_FLOW_BOX (flow), GTK_SELECTION_NONE);
    gtk_flow_box_set_homogeneous (GTK_FLOW_BOX (flow), TRUE);
    gtk_flow_box_set_min_children_per_line (GTK_FLOW_BOX (flow), 2);
    gtk_flow_box_set_max_children_per_line (GTK_FLOW_BOX (flow), 5);
    gtk_flow_box_set_column_spacing (GTK_FLOW_BOX (flow), 18);

    for (gsize i = 0; i < section->count; i++)
        gtk_flow_box_append (GTK_FLOW_BOX (flow), byk_layout_cell (&section->entries[i]));

    adw_preferences_group_add (ADW_PREFERENCES_GROUP (group), flow);
    return group;
}

GtkWidget *
byk_layout_page_new (void)
{
    GtkWidget *page = adw_preferences_page_new ();

    GtkWidget *intro = adw_preferences_group_new ();
    adw_preferences_group_set_description (
        ADW_PREFERENCES_GROUP (intro),
        "Byakaron types Avro Phonetic. Capital letters are their own keys, not "
        "shifted versions of the lowercase ones — T is ট, not ত.");
    adw_preferences_page_add (ADW_PREFERENCES_PAGE (page), ADW_PREFERENCES_GROUP (intro));

    for (gsize i = 0; i < G_N_ELEMENTS (SECTIONS); i++)
        adw_preferences_page_add (ADW_PREFERENCES_PAGE (page),
                                  ADW_PREFERENCES_GROUP (byk_layout_group (&SECTIONS[i])));

    return page;
}
