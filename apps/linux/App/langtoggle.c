#include "langtoggle.h"

#define BYK_LANG_SIZE 22          /* the circle's box, in pixels */
#define BYK_LANG_SWAP_US 200000   /* how long the letters take to swap */

typedef struct {
    GtkWidget *button;
    GtkWidget *area;
    gdouble at;    /* 0: A large (off) … 1: ক large (on) */
    gdouble from;
    gdouble to;
    gint64 start;  /* the swap's first frame, 0 before it is drawn */
    guint tick;
} BykLangToggle;

static gdouble
byk_lerp (gdouble a, gdouble b, gdouble t)
{
    return a + (b - a) * t;
}

/* Fast out, gentle in: the letters jump away and settle. */
static gdouble
byk_ease_out (gdouble t)
{
    const gdouble u = 1.0 - t;
    return 1.0 - u * u * u;
}

/* `text` centred on (cx, cy) by its ink, `px` pixels tall. */
static void
byk_draw_letter (cairo_t *cr, GtkWidget *widget, const gchar *text,
                 gdouble cx, gdouble cy, gdouble px, const GdkRGBA *color)
{
    PangoLayout *layout = gtk_widget_create_pango_layout (widget, text);
    PangoFontDescription *font = pango_font_description_copy (
        pango_context_get_font_description (gtk_widget_get_pango_context (widget)));
    PangoRectangle ink;

    pango_font_description_set_absolute_size (font, px * PANGO_SCALE);
    pango_font_description_set_weight (font, PANGO_WEIGHT_BOLD);
    pango_layout_set_font_description (layout, font);
    pango_layout_get_pixel_extents (layout, &ink, NULL);
    gdk_cairo_set_source_rgba (cr, color);
    cairo_move_to (cr, cx - ink.x - ink.width / 2.0, cy - ink.y - ink.height / 2.0);
    pango_cairo_show_layout (cr, layout);
    pango_font_description_free (font);
    g_object_unref (layout);
}

static gboolean
on_draw (GtkWidget *area, cairo_t *cr, gpointer user_data)
{
    BykLangToggle *t = user_data;
    GtkStyleContext *style = gtk_widget_get_style_context (t->button);
    const gdouble w = gtk_widget_get_allocated_width (area);
    const gdouble h = gtk_widget_get_allocated_height (area);
    const gdouble size = MIN (w, h);
    const gdouble p = t->at;
    GdkRGBA fg, accent, on_fg = { 1.0, 1.0, 1.0, 1.0 }, color;

    gtk_style_context_get_color (style, gtk_style_context_get_state (style), &fg);
    /* main.c's accent, dark enough for white letters (4.9:1). */
    if (!gtk_style_context_lookup_color (style, "byk_accent_dark", &accent) &&
        !gtk_style_context_lookup_color (style, "theme_selected_bg_color", &accent))
        accent = fg;

    /* The circle a little up and left, the small letter in the lower right
     * on a notch cut out of it, like a badge. */
    const gdouble ox = (w - size) / 2.0, oy = (h - size) / 2.0;
    const gdouble r = size * 0.40;
    const gdouble cx = ox + size * 0.44, cy = oy + size * 0.44;
    const gdouble small_x = ox + size * 0.80, small_y = oy + size * 0.80, small = size * 0.36;
    const gdouble notch = size * 0.25;
    const gdouble big_x = cx, big_y = cy, big = r * 1.05;

    cairo_push_group (cr);
    cairo_arc (cr, cx, cy, r, 0, 2 * G_PI);
    cairo_set_source_rgba (cr, accent.red, accent.green, accent.blue, accent.alpha * p);
    cairo_fill_preserve (cr);
    cairo_set_line_width (cr, 1.5);
    cairo_set_source_rgba (cr, fg.red, fg.green, fg.blue, fg.alpha * (1.0 - p));
    cairo_stroke (cr);
    cairo_set_operator (cr, CAIRO_OPERATOR_CLEAR);
    cairo_arc (cr, small_x, small_y, notch, 0, 2 * G_PI);
    cairo_fill (cr);
    cairo_pop_group_to_source (cr);
    cairo_paint (cr);

    /* A goes from large in the outline (text colour) to the notch (text
     * colour); ক from the notch to large on the accent (white). */
    color = fg;
    color.alpha = fg.alpha * byk_lerp (1.0, 0.85, p);
    byk_draw_letter (cr, area, "A", byk_lerp (big_x, small_x, p), byk_lerp (big_y, small_y, p),
                     byk_lerp (big, small, p), &color);
    color.red = byk_lerp (fg.red, on_fg.red, p);
    color.green = byk_lerp (fg.green, on_fg.green, p);
    color.blue = byk_lerp (fg.blue, on_fg.blue, p);
    color.alpha = fg.alpha * byk_lerp (0.85, 1.0, p);
    byk_draw_letter (cr, area, "ক", byk_lerp (small_x, big_x, p), byk_lerp (small_y, big_y, p),
                     byk_lerp (small, big, p) * 1.1, &color);
    return FALSE;
}

static gboolean
on_tick (GtkWidget *area, GdkFrameClock *clock, gpointer user_data)
{
    BykLangToggle *t = user_data;
    const gint64 now = gdk_frame_clock_get_frame_time (clock);

    if (t->start == 0)
        t->start = now;
    const gdouble f = (gdouble) (now - t->start) / BYK_LANG_SWAP_US;
    if (f >= 1.0) {
        t->at = t->to;
        t->tick = 0;
        gtk_widget_queue_draw (area);
        return G_SOURCE_REMOVE;
    }
    t->at = byk_lerp (t->from, t->to, byk_ease_out (f));
    gtk_widget_queue_draw (area);
    return G_SOURCE_CONTINUE;
}

static void
on_toggled (GtkToggleButton *button, gpointer user_data)
{
    BykLangToggle *t = user_data;
    const gboolean on = gtk_toggle_button_get_active (button);
    gboolean animate = TRUE;

    gtk_widget_set_tooltip_text (GTK_WIDGET (button),
                                 on ? "Bangla typing is on: keys type Bangla here, "
                                      "whatever the system keyboard. Ctrl+T turns it off"
                                    : "Bangla typing is off: the system keyboard types here. "
                                      "Ctrl+T turns it on");

    g_object_get (gtk_widget_get_settings (GTK_WIDGET (button)),
                  "gtk-enable-animations", &animate, NULL);
    if (!animate || !gtk_widget_get_mapped (t->area)) {
        if (t->tick != 0) {
            gtk_widget_remove_tick_callback (t->area, t->tick);
            t->tick = 0;
        }
        t->at = on ? 1.0 : 0.0;
        gtk_widget_queue_draw (t->area);
        return;
    }
    t->from = t->at;
    t->to = on ? 1.0 : 0.0;
    t->start = 0;
    if (t->tick == 0)
        t->tick = gtk_widget_add_tick_callback (t->area, on_tick, t, NULL);
}

static void
on_area_destroy (GtkWidget *area, gpointer user_data)
{
    BykLangToggle *t = user_data;

    if (t->tick != 0) {
        gtk_widget_remove_tick_callback (area, t->tick);
        t->tick = 0;
    }
}

GtkWidget *
byk_lang_toggle_new (const gchar *action)
{
    BykLangToggle *t = g_new0 (BykLangToggle, 1);

    t->button = gtk_toggle_button_new ();
    t->area = gtk_drawing_area_new ();
    gtk_widget_set_size_request (t->area, BYK_LANG_SIZE, BYK_LANG_SIZE);
    gtk_container_add (GTK_CONTAINER (t->button), t->area);
    gtk_style_context_add_class (gtk_widget_get_style_context (t->button), "image-button");
    gtk_style_context_add_class (gtk_widget_get_style_context (t->button), "byk-lang-toggle");
    gtk_widget_set_valign (t->button, GTK_ALIGN_CENTER);
    atk_object_set_name (gtk_widget_get_accessible (t->button), "Bangla typing");

    /* Freed with the drawing area; the tick stops when it is destroyed. */
    g_object_set_data_full (G_OBJECT (t->area), "byk-lang-toggle", t, g_free);
    g_object_set_data (G_OBJECT (t->button), "byk-lang-toggle", t);
    g_signal_connect (t->area, "draw", G_CALLBACK (on_draw), t);
    g_signal_connect (t->area, "destroy", G_CALLBACK (on_area_destroy), t);
    g_signal_connect (t->button, "toggled", G_CALLBACK (on_toggled), t);

    on_toggled (GTK_TOGGLE_BUTTON (t->button), t);
    gtk_actionable_set_action_name (GTK_ACTIONABLE (t->button), action);
    gtk_widget_show (t->area);
    return t->button;
}

gdouble
byk_lang_toggle_position (GtkWidget *button)
{
    BykLangToggle *t = g_object_get_data (G_OBJECT (button), "byk-lang-toggle");
    return t != NULL ? t->at : -1.0;
}
