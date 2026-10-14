# wayland_rdtest.py <label> <reader-cmd...>: type through org.gnome.Mutter.RemoteDesktop,
# the compositor's own input path, and check what the app received (the reader
# prints its text). One D-Bus connection holds the session: it ends when the
# connection that created it closes.
import sys, time, subprocess
from gi.repository import Gio, GLib
label, reader = sys.argv[1], sys.argv[2:]
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
RD = 'org.gnome.Mutter.RemoteDesktop'
def call(path, iface, method, params=None):
    return bus.call_sync(RD, path, iface, method, params, None, 0, -1, None)
sess = call('/org/gnome/Mutter/RemoteDesktop', RD, 'CreateSession').unpack()[0]
call(sess, RD + '.Session', 'Start')
def sym(ks, down): call(sess, RD + '.Session', 'NotifyKeyboardKeysym', GLib.Variant('(ub)', (ks, down)))
def key(ks): sym(ks, True); time.sleep(0.03); sym(ks, False); time.sleep(0.06)
def typ(s):
    for c in s: key(ord(c))
def ctrl(c): sym(0xffe3, True); key(ord(c)); sym(0xffe3, False); time.sleep(0.1)
def click():
    for down in (True, False):
        call(sess, RD + '.Session', 'NotifyPointerButton', GLib.Variant('(ib)', (272, down))); time.sleep(0.05)
    time.sleep(0.3)
def text(): return subprocess.run(reader, capture_output=True, text=True).stdout
fails = 0
def t(name, exp, action):
    global fails
    ctrl('a'); key(0xff08); time.sleep(0.4); action(); time.sleep(1.2); got = text()
    ok = got == exp; fails += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} {label} {name} -> [{got}]" + ('' if ok else f" expected [{exp}]"), flush=True)
t("ami bangla + space", "আমি বাংলা ", lambda: typ("ami bangla "))
t("bhalO. (Shift)", "ভালো। ", lambda: typ("bhalO. "))
t("2026 numerals", "২০২৬ ", lambda: typ("2026 "))
t("pick candidate 2", "আমিন", lambda: (typ("ami"), time.sleep(0.4), key(ord('2'))))
t("click commits once", "আমি", lambda: (typ("ami"), time.sleep(0.4), click()))
t("Down Down Enter", "আমিন", lambda: (typ("ami"), time.sleep(0.4), key(0xff54), key(0xff54), time.sleep(0.2), key(0xff0d)))
call(sess, RD + '.Session', 'Stop')
sys.exit(1 if fails else 0)
