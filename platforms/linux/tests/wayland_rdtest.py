# wayland_rdtest.py <label> <reader-cmd...>: type through org.gnome.Mutter.RemoteDesktop,
# the compositor's own input path, and check what the app received (the reader
# prints its text). One D-Bus connection holds the session: it ends when the
# connection that created it closes.
import os, sys, time, subprocess
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
# The window can be on screen before it has keyboard focus and its input
# context is wired to IBus (slow CI runners: the first checks got nothing).
# Type until the whole path answers, then start.
def warm_up(limit=30.0):
    start = time.time()
    while time.time() - start < limit:
        ctrl('a'); key(0xff08); time.sleep(0.3)
        typ("ami "); time.sleep(1.0)
        if text() == "আমি ":
            return True
        time.sleep(1.0)
    return False

if not warm_up():
    print(f"  FAIL {label} never received keys through IBus (30 s)", flush=True)
    sys.exit(1)

t("ami bangla + space", "আমি বাংলা ", lambda: typ("ami bangla "))
t("bhalO. (Shift)", "ভালো। ", lambda: typ("bhalO. "))
t("2026 numerals", "২০২৬ ", lambda: typ("2026 "))
t("pick candidate 2", "আমিন", lambda: (typ("ami"), time.sleep(0.4), key(ord('2'))))
t("click commits once", "আমি", lambda: (typ("ami"), time.sleep(0.4), click()))
t("Down Down Enter", "আমিন", lambda: (typ("ami"), time.sleep(0.4), key(0xff54), key(0xff54), time.sleep(0.2), key(0xff0d)))
import os
if os.environ.get("BYK_SPELL_DB_PRESENT") == "1":
    # The correction arrives from the engine's worker thread after the keystroke.
    t("sonar + 2 (spelling fix)", "সোনার", lambda: (typ("sonar"), time.sleep(1.0), key(ord('2'))))
if os.environ.get("BYK_SETTINGS_TEST") == "1":
    # Settings apply live: flip one with gsettings while the keyboard runs.
    def gset(key, value):
        subprocess.run(["gsettings", "set", "dev.nuhu.labs.Byakaron", key, value], check=True)
        time.sleep(0.5)
    gset("bangla-digits", "false")
    t("Bangla digits off: 2026", "2026 ", lambda: typ("2026 "))
    gset("bangla-digits", "true")
    t("Bangla digits on: 2026", "২০২৬ ", lambda: typ("2026 "))
call(sess, RD + '.Session', 'Stop')
sys.exit(1 if fails else 0)
