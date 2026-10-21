# wayland_textapp.py <3|4> <outfile>: fullscreen GTK TextView that mirrors its text into
# outfile. Driven by scripts/gnome_wayland_test.sh.
import sys, gi
ver, out = sys.argv[1], sys.argv[2]
gi.require_version('Gtk', '3.0' if ver == '3' else '4.0')
from gi.repository import Gtk, Gdk
def dump(buf, *a):
    s, e = buf.get_bounds()
    with open(out, 'w') as f: f.write(buf.get_text(s, e, False))
def report():
    print(f"[app] GTK{ver} display={type(Gdk.Display.get_default()).__name__}", flush=True)
if ver == '3':
    w = Gtk.Window(); tv = Gtk.TextView(); w.add(tv)
    tv.get_buffer().connect('changed', dump); w.connect('destroy', Gtk.main_quit)
    w.show_all(); w.fullscreen(); tv.grab_focus(); report(); Gtk.main()
else:
    app = Gtk.Application()
    def act(a):
        w = Gtk.ApplicationWindow(application=a); tv = Gtk.TextView(); w.set_child(tv)
        tv.get_buffer().connect('changed', dump); w.present(); w.fullscreen(); tv.grab_focus(); report()
    app.connect('activate', act); app.run([])
