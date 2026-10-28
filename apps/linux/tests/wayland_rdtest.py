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
# The keyboard's data directory (settings.json, selections.json), as the engine
# finds it.
data = os.environ.get("BYAKARON_DATA_DIR") or os.path.join(
    os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "byakaron")
def forget():
    # Avro remembers each pick and opens the word on it next time; start every
    # check from Avro's own order. The engine re-reads the file when a word starts.
    os.makedirs(data, exist_ok=True)
    with open(os.path.join(data, "selections.json"), "w") as f: f.write("{}")
def run(action):
    forget(); ctrl('a'); key(0xff08); time.sleep(0.4); action(); time.sleep(1.2)
    return text()
fails = 0
def report(name, got, ok, exp):
    global fails
    fails += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} {label} {name} -> [{got}]" + ('' if ok else f" expected [{exp}]"), flush=True)
def t(name, exp, action):
    got = run(action)
    report(name, got, got == exp, exp)
# A new window does not always get keyboard focus: on GitHub's runner GNOME
# Shell left it unfocused, so keys went nowhere until the first click (the
# click-commit check). Click into it, the way a user clicks into a text box,
# then type until the whole path to IBus answers.
def warm_up(limit=60.0):
    start = time.time()
    seen = []
    forget()
    while time.time() - start < limit:
        click()
        ctrl('a'); key(0xff08); time.sleep(0.3)
        typ("ami "); time.sleep(1.0)
        got = text()
        if got == "আমি ":
            print(f"  info {label} ready after {time.time() - start:.1f} s", flush=True)
            return True
        seen.append(got)
        time.sleep(1.0)
    print(f"  info {label} warm-up saw: {seen[:3]} ... {seen[-2:]}", flush=True)
    return False

if not warm_up():
    print(f"  FAIL {label} never received keys through IBus (60 s)", flush=True)
    sys.exit(1)

t("ami bangla + space", "আমি বাংলা ", lambda: typ("ami bangla "))
t("bhalO. (Shift)", "ভালো। ", lambda: typ("bhalO. "))
t("2026 numerals", "২০২৬ ", lambda: typ("2026 "))
# Only Avro's first candidate for "ami" is pinned (as in ime_test.c); the others
# are checked against each other, so a dictionary change does not break them.
second = run(lambda: (typ("ami"), time.sleep(0.4), key(ord('2'))))
report("pick candidate 2", second, second not in ("", "আমি") and not second.endswith(" "), "a word other than আমি")
# Remember my choices: the pick is learned, so the next "ami" opens on it and
# Space takes it.
t("Remember my choices", f"{second} {second} ",
  lambda: (typ("ami"), time.sleep(0.4), key(ord('2')), time.sleep(0.3), typ(" ami ")))
t("click commits once", "আমি", lambda: (typ("ami"), time.sleep(0.4), click()))
third = run(lambda: (typ("ami"), time.sleep(0.4), key(ord('3'))))
t("Down Down Enter", third, lambda: (typ("ami"), time.sleep(0.4), key(0xff54), key(0xff54), time.sleep(0.2), key(0xff0d)))
if os.environ.get("BYK_SPELL_DB_PRESENT") == "1":
    # The composer lists Avro's dictionary words first, so সোনার is already
    # first for "sonar" (corrections are only added when Avro has none).
    t("sonar + Space (dictionary word first)", "সোনার ", lambda: typ("sonar "))
if os.environ.get("BYK_SETTINGS_TEST") == "1":
    # Settings apply from the next word: flip one in settings.json (what the app
    # writes through its composer) while the keyboard runs.
    import json
    def setting(key, value):
        path = os.path.join(data, "settings.json")
        try:
            with open(path) as f: s = json.load(f)
        except (OSError, ValueError):
            s = {}
        s[key] = value
        os.makedirs(data, exist_ok=True)
        with open(path, "w") as f: json.dump(s, f)
        time.sleep(0.5)
    setting("bangla_digits", False)
    t("Bangla digits off: 2026", "2026 ", lambda: typ("2026 "))
    setting("bangla_digits", True)
    t("Bangla digits on: 2026", "২০২৬ ", lambda: typ("2026 "))
call(sess, RD + '.Session', 'Stop')
sys.exit(1 if fails else 0)
