# Byakaron for Linux

Bangla phonetic input method and companion app for Linux, driven by the same
Zig engine as the macOS and Windows ports through its C ABI (`src/ffi/byakaron.h`).

## How this fits the other platforms

| Layer | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Keyboard / IME | Swift + InputMethodKit | C++ + TSF | **C + IBus** |
| GUI app | SwiftUI | C# WinUI 3 | **C + GTK3** |
| Engine linkage | static `libbyakaron.a` | shared `byakaron.dll` | **static into both binaries** |

Every port is a thin platform shell; all Bangla logic — transliteration, spell
check, autocomplete — stays in Zig behind the C ABI.

## Why IBus

Linux has no single "add a keyboard layout" API that can do phonetic input:

- **XKB** (what `xkeyboard-config` layouts like *Bengali (Probhat)* use) is a pure
  keycode-to-symbol mapping. It cannot buffer a syllable, run transliteration
  across several keystrokes, or present candidates. It suits fixed layouts and
  cannot express Avro phonetic at all.
- **IBus** is an input-method *framework*: an engine process receives raw key
  events, maintains a preedit string, and commits text to the focused
  application. That is the same shape as macOS `InputMethodKit` and Windows TSF.

An IBus engine registers as a first-class OS input source — it shows up in
GNOME Settings → Keyboard → Input Sources and switches with Super+Space, so the
user adds and switches Bangla exactly the way they would any other language.

IBus is also the default on GNOME (Ubuntu, Fedora, Debian) and reaches
applications through the GTK and Qt im-modules, XIM, and Wayland's
`text-input-v3`.

Fcitx5 is a possible second front-end; `Core/composer.c` is what it wraps.
IBus remains the GNOME/Ubuntu default.

## Why C

`libibus` is a GObject/C library, so a C engine includes `<ibus.h>` and
`"byakaron.h"` side by side with no binding layer — the same relationship the
Windows C++ TSF service has to the DLL. It compiles as part of `build.zig`
(`addCSourceFile` + `linkSystemLibrary("ibus-1.0")`), so the port adds no second
build system and no extra language runtime on the per-keystroke path.

## Layout

```
platforms/linux/
├── App/         GTK3 app (main, window, spelling, layout, setup)
├── Core/        Shared C glue over byakaron.h (composer, transliterator,
│                autocomplete, spell, prefs) — IBus, Fcitx5, and the app all use this
├── Keyboard/    The IBus engine (thin shell over Core/composer)
├── Fcitx5/      Optional Fcitx5 addon (same composer; needs libfcitx5core-dev)
├── Resources/   IBus component XML, GSettings schema, .desktop, icons, Flatpak manifest
├── scripts/     setup_deps.sh, build_zig.sh, smoke.sh, prepare_spell_db.sh,
│                install.sh, uninstall.sh, package_deb.sh, package_flatpak.sh,
│                ci.sh, wayland_probe.sh, wayland_type.sh
└── tests/       C ABI + Core smoke test, IBus integration test, Wayland probes
```

`Core/` holds the glue that every Linux front-end needs: `transliterator.c` for
latin → Bangla, `autocomplete.c` for candidates, `spell.c` for spell.db,
`composer.c` for the key policy (what Space, 1–9, digits, punctuation, Escape
mean), and `prefs.c` for the GSettings schema both the engine and the app
read. IBus and Fcitx5 are thin shells over that composer
so they cannot drift. All four hand back plain `g_malloc`'d memory, so the Zig
ownership rule (`byakaron_string_free`) and the JSON the ABI returns stop there
and nothing above them has to know.

The two binaries share `Core/` as source and each links its own static copy of
the Zig core. A single `libbyakaron.so` would save ~7 MB of the download, at the
cost of a SONAME, an `ldconfig` trigger and an ABI promise this version is not
in a position to make; `-Dshared` still builds the `.so` for anyone who wants
to link it.

## Getting set up

### 1. System packages

```bash
sudo bash platforms/linux/scripts/setup_deps.sh
```

### 2. Zig

This branch is pinned to **`0.17.0-dev.1422+e863bf3be`**. Newer builds do not
work — Zig master renamed the `Optimize` enum, which breaks the `ziex`
dependency. Note that `.tool-versions` says `zig master`; that is stale.

ziglang.org prunes old dev builds, so fetch it from a community mirror.
On **ARM64** (Raspberry Pi / Ubuntu `aarch64`), use the aarch64 tarball instead
— see [ARM.md](ARM.md).

```bash
V=0.17.0-dev.1422+e863bf3be
curl -fSL -o /tmp/zig.tar.xz \
  "https://pkg.hexops.org/zig/builds/zig-x86_64-linux-$V.tar.xz"
tar -C ~/.local -xf /tmp/zig.tar.xz
ln -sfn ~/.local/zig-x86_64-linux-$V/zig ~/.local/bin/zig
```

### 3. The `ziex` path dependency

`build.zig.zon` refers to `ziex` by relative path (`../../ziex-dev/ziex`), so it
must be checked out as a sibling of the repository's parent directory:

```bash
git clone https://github.com/ziex-dev/ziex.git ~/ziex-dev/ziex
git -C ~/ziex-dev/ziex checkout 29f9a85b
```

Commit `29f9a85b` matters: the commit after it removes the `exclude-core-lang`
build option that our `build.zig` passes.

### 4. Verify the engine

```bash
bash platforms/linux/scripts/smoke.sh
```

This builds `libbyakaron.so` and calls it from C. Expect `ami → আমি`,
`bangla → বাংলা`, and autocomplete candidates. It also covers the candidate JSON
parser in `Core/autocomplete.c`, including the inputs it must *reject* — those
paths are unreachable through the engine, because the only producer of that JSON
is in this repository and never emits malformed output.

## Building and running the input method

```bash
zig build linux          # -> zig-out/bin/byakaron-ibus
zig build linux-app      # -> zig-out/bin/byakaron       (the GTK app)
zig build linux-fcitx5   # -> zig-out/lib/fcitx5/byakaron.so  (optional)
zig build run-linux-app  # build and run the app
```

The engine binary links the Zig core statically, so it is self-contained apart
from system IBus and GLib. `linux-app` is a separate step on purpose: the engine
must stay buildable on a box that has only `libibus-1.0-dev`, while the app also
needs `libgtk-3-dev`. GTK3 3.24 is on Ubuntu 20.04, 22.04, and 24.04. `linux-fcitx5` is a third step for
the same reason: it needs `libfcitx5core-dev`, which a GNOME box does not have,
and installing those headers does not switch the session's input method.

### Development run

```bash
bash platforms/linux/scripts/dev_run.sh
```

Registers the engine with the *running* `ibus-daemon` straight from the build
tree — nothing is copied into `/usr`, and the registration disappears when the
process exits. While it runs, `ibus engine byakaron` switches to it and
`ibus engine xkb:us::eng` switches back.

Permanent installation (so the engine survives a reboot and shows up in
Settings → Keyboard → Input Sources) is `scripts/install.sh`.

### Integration test

```bash
bash platforms/linux/scripts/test_ime.sh
```

Starts a throwaway engine, drives it through a *private* IBus input context, and
shuts it down. Because the context is private, the desktop's own input source is
never touched. It asserts the preedit while typing, that Backspace
re-transliterates from the latin buffer, that Space commits, that Escape
discards, that a multi-word sentence commits correctly, and that the candidate
list appears, selects by number, and pages.

The test claims `IBUS_CAP_LOOKUP_TABLE` so the daemon routes candidates to it;
without that capability the table goes to the desktop panel and a client never
sees it.

## How the engine works

The **latin text the user typed is the single source of truth**. Every keystroke
re-transliterates the whole buffer and replaces the preedit wholesale.

That matters because transliteration is contextual: a later keystroke can change
a glyph already on screen, and one Bangla conjunct can span several latin
characters. Editing the Bangla directly — deleting one Bangla character on
Backspace, say — would split conjuncts and desynchronise the two buffers.
Backspace therefore drops one *latin* character and re-runs the whole word. The
engine handle is built once per input context, so re-running is cheap.

Key handling:

| Key | Behaviour |
| --- | --- |
| `a`–`z`, `A`–`Z` | Appended to the latin buffer; preedit updates |
| `0`–`9` | Bangla numerals (`1` → `১`, `2024` → `২০২৪`), except `1`–`9` pick a candidate while the list is on screen |
| `.` `,` `:` `$` `^` backtick and other printable ASCII | Appended; Avro maps `.` → `।`, `:` → `ঃ`, `$` → `৳`, `^` → `ঁ` |
| Backspace | Drops one latin character and re-transliterates |
| Space | Commits the Bangla plus the space, in one commit |
| Enter | Commits the highlighted candidate if an arrow key chose one (Enter is consumed); otherwise commits the word, then lets the application see the Enter |
| Escape | Discards the pending word and its candidates |
| `1`–`9` | Picks that candidate — but only while the list is on screen |
| Down / Right, Up / Left | Moves a highlight through the candidates, across pages, while the list is on screen. Nothing is highlighted until the first arrow; Up from the first candidate removes it. Without a list the arrows commit the word and move the caret as usual |
| Page Up / Page Down | Turns the candidate page, while the list is on screen |
| Ctrl/Alt/Super + key | Commits the word, then passes the shortcut through |
| Anything else | Commits the word and is handled by the application |

Space and Enter commit the terminator themselves rather than letting the key
fall through, because `commit_text` travels over D-Bus and a forwarded key is
not guaranteed to arrive after it.

## Candidates

While a word is being typed, the panel lists dictionary words that start with it
and the number keys pick one. Candidates come from `byakaron_ac_prefix`, whose
lexicon is compiled into the binary, so they work with nothing installed — no
`spell.db`, no database at all. Building the word index costs ~7ms once per
process and each lookup ~10µs, both measured, so this sits comfortably on the
per-keystroke path.

The list is kept out of the way like this:

- **Only the number keys select, and only while the list is visible.** Space
  and Enter always commit what was *typed*, never a candidate. Off-screen,
  `0`–`9` become Bangla numerals (`1` → `১`). `0` is never a candidate key, so
  it always types `০`. The list is drawn without a selection highlight until an
  arrow key moves one (then Enter takes it); Space never does.

Escape drops the word and the list together rather than dismissing the list
first: a two-stage Escape would mean two different things depending on state the
user can no longer see once the list is gone.

The panel's own paging arrows and mouse clicks work too — the engine implements
the `page_up`, `page_down`, `cursor_up`, `cursor_down` and `candidate_clicked`
handlers the panel drives.

### Spelling corrections

When nothing in the dictionary starts with the word Avro produced, it is
probably misspelled (`sonar` → সনার, `shundor` → শুন্দর, `jibon` → জিবন), and
there used to be no list at all. `Core/corrector.c` now asks spell.db for up to
three corrections and lists them *after* the typed word, which stays first so
Space and `1` keep meaning "as typed": `sonar` then `2` types সোনার. Correctly
spelled words keep their normal list. Single letters are skipped.

A correction lookup is 0.2–10 ms warm but up to ~150 ms on a cold disk cache,
too slow for the keystroke path. In the IBus engine it runs on one worker
thread with its own spell.db connection; when a word's corrections arrive and
it is still the word on screen, the list updates by itself. Results are
cached. The Fcitx5 addon has no GLib main loop for that callback, so it looks
up inline (cached too): a new misspelled word can stall that keystroke once.

Needs spell.db; without it nothing changes. GSettings key
`spelling-suggestions` (default on) turns it off, live.

### Personal dictionary

Words the user marks as correct live in
`~/.local/share/byakaron/user-words.txt` (one per line, NFC, sorted, written
atomically; `BYAKARON_USER_DICT` overrides the path for tests).
`Core/userdict.c` is shared by both sides:

- **App:** "Add to Dictionary" next to Ignore in the Spelling page (Ignore
  still lasts only until the app closes), and *Personal Dictionary…* in the
  main menu to add a word by hand or remove one. Saved words are never flagged.
- **Keyboard:** saved words that start with what is being typed are suggested
  right after the first candidate, and a saved word is never offered spelling
  corrections. The engine re-reads the file at most once a second on a
  keystroke and compares contents, so a word added in the app works in the
  keyboard without restarting either.

Changes are detected by comparing contents rather than `stat()`: built by Zig
against its bundled glibc headers, `struct stat` was smaller than what the
system's `stat()` writes, and the overflow crashed the app at start once the
file existed. GIO was ruled out too: it can load GVfs and block on D-Bus.
The app-only Flatpak has its own data directory, so its dictionary is not the
keyboard's.

## The app

A separate process (`byakaron`) from the engine, sharing only `Core/` and the
Zig core underneath. The input method works whether or not it is installed or
running. Three pages, reached from the header-bar menu; the window opens on
**Spelling** and the header title names the current page. `byakaron --page=setup`
opens Setup (that is what the IBus panel **Preferences** button runs).

| Page | What it is for |
| --- | --- |
| **Spelling** | Editor with an issue list, red squiggles, and Fix All |
| **Layout** | The Avro key map, as a lookup table |
| **Setup** | Keyboard status, the steps to add it, a typing cheat-sheet |

**Spelling checks per word, not with `byakaron_spell_check`.** The bulk call
returns a JSON array of tokens with nested suggestion objects; the app already
has to know each word's position in the buffer to underline it, so it tokenises
locally and calls `byakaron_spell_is_correct` per word — which is what the macOS
and Windows apps do too. Only Bengali-block runs are checked, so latin,
punctuation and emoji are left alone rather than reported as misspelled, and
Bangla digits are skipped because `২০২৪` is not a misspelling.

Suggestions use plain `byakaron_spell_suggest`, not the `_ctx` variant: context
ranking reads bigram and trigram tables that the locally built `spell.db` has
empty, so passing neighbours would cost two queries per word for identical
output. Worth revisiting when the n-grams exist.

`spell.db` is 364 MB, so it opens on a worker thread. The window paints
immediately, the Spelling page shows a loading state, and with no database at
all it says so and stays out of the way — Layout and Setup need nothing
installed.

**Setup checks two things, because on Linux they are two steps.** Whether the
IBus component is registered under `/usr/share/ibus/component` (the install),
and whether `byakaron` is in the user's `org.gnome.desktop.input-sources`
(adding it in Settings). That distinction is what separates "run the installer"
from "click **+** in Settings". The GSettings schema is looked up before use,
since `g_settings_new` aborts the process on an unknown schema and that schema
does not exist outside GNOME.

**Preferences that change behaviour live in GSettings**
(`dev.nuhu.labs.Byakaron`). Setup exposes two switches that the IBus engine
and the Fcitx5 addon read:

- **Suggest words** — off is phonetic-only: transliteration stays, the
  dictionary candidate list is hidden, so 1–9 type Bangla numerals.
- **Horizontal candidate list** — the IME panel.

Flipping a switch updates the engine without a restart. There are no
macOS-style "Coming soon" toggles. Candidates-per-page stays at 9 because
1–9 are the selection keys.

## Installing permanently

```bash
sudo bash platforms/linux/scripts/install.sh
```

This is a **system** install (`/usr/libexec`, `/usr/share/ibus/component`,
`/usr/share/icons/...`) and must be, not a preference: `ibus-daemon` builds its
registry by scanning `/usr/share/ibus/component` only. A copy under
`~/.local/share/ibus/component` is never read, and `IBUS_COMPONENT_PATH` is not
honoured by ibus 1.5.x either — both verified directly against the installed
1.5.29 daemon before writing this. Every other engine on the system, including
`ibus-avro`, installs the same way.

The script builds as the invoking (non-root) user via `SUDO_USER`, so `zig`
resolves from that user's `~/.local/bin` and no root-owned build artifacts are
left in the repo. It refreshes the ibus registry and restores whatever input
engine was active before, since restarting the daemon otherwise drops it.
The GSettings schema is compiled into `/usr/share/glib-2.0/schemas` so Setup
toggles reach the engine.

The app is installed too when `gtk+-3.0` is present, to
`/usr/bin/byakaron` with a `.desktop` entry — `/usr/bin`, not `/usr/libexec`,
because the user launches it, unlike the engine, which only `ibus-daemon` ever
execs. It is skipped rather than fatal when those libraries are missing, since
the input method is the product. Installing it also fills in the component
XML's `<setup>` element, which is what makes the IBus panel's **Preferences**
button open `byakaron --page=setup`; that element stays empty otherwise, because a setup command
pointing at a missing binary gives a button that silently does nothing.

After installing:

1. Settings → Keyboard → Input Sources → **+**
2. Choose **Bangla**, then **Byakaron (Bangla Phonetic)** → Add
   (the first dialog is a language list — searching "Byakaron" there finds nothing)
3. Switch with **Super+Space**

```bash
sudo bash platforms/linux/scripts/uninstall.sh
```

removes everything install.sh added.

## Wayland

The engine never opens a display. `Keyboard/` includes neither X11 nor Wayland
headers; it only implements `IBusEngine`, and the daemon is what delivers those
events to the focused client. X11 vs Wayland is a *client* question:

| Session | What a GTK4 text field uses (GTK_IM_MODULE unset) |
| --- | --- |
| X11 (this development box) | `GtkIMMulticontext` context id `ibus` → `libim-ibus.so` → D-Bus |
| Wayland | context id `wayland` → `GtkIMContextWayland` → `zwp_text_input_v3` → compositor (Mutter) → IBus |

Both end at the same engine. Setting `GTK_IM_MODULE=ibus` forces the D-Bus
module on either backend; GNOME on Wayland often leaves it unset and uses
text-input-v3 instead.

### Tested on a real GNOME Shell Wayland session

`scripts/gnome_wayland_test.sh` starts a **private** `gnome-shell --headless
--wayland` (own D-Bus, dconf, runtime dir and ibus-daemon, input source set to
Byakaron) next to the running desktop, opens GTK3 and GTK4 windows natively on
it, and types through `org.gnome.Mutter.RemoteDesktop`. Those keys take the
same path as a keyboard on an "Ubuntu on Wayland" login: text-input-v3 →
GNOME Shell → IBus → `byakaron-ibus`. Five checks per toolkit: `ami bangla `,
Shift (`bhalO.` → ভালো।), Bangla numerals, picking candidate 2, and a click
while a word is pending (committed once). Switching the input source to
English makes every check fail, so the test does measure the engine.

```bash
zig build linux
bash platforms/linux/scripts/gnome_wayland_test.sh   # GTK3 + GTK4, 10 checks
```

Qt was checked the same way from a container sharing the sandbox's Wayland
and IBus sockets (not scripted here):

| Qt on GNOME Wayland | Result |
| --- | --- |
| Qt 5.15 / 6.4, `QT_IM_MODULE=ibus` (Ubuntu's default session setting) | typing, Shift, numerals, candidates pass |
| Qt 6.4 without `QT_IM_MODULE` | plain latin: Qt 6.4 has no text-input-v3, so no IME of any kind reaches it |

A click *inside* a Qt field could not be synthesised on headless Wayland (the
pointer cannot be placed without a screen-cast stream); the same IBus path is
covered by the X11 Qt test.

`scripts/wayland_probe.sh` and `scripts/wayland_type.sh` remain as the quick
nested-mutter checks used by `ci.sh`.

## CI

`.github/workflows/linux.yml` runs on every push and pull request:

1. Ubuntu packages (`libibus-1.0-dev`, `libgtk-3-dev`, `libgtk-4-dev` for IME tests, `libfcitx5core-dev`, `ibus`, `xvfb`)
2. Zig **0.17.0-dev.1422+e863bf3be** via `mlugg/setup-zig` (not master)
3. Clone `ziex` at commit `29f9a85b` to `../../ziex-dev/ziex`, which is what
   `build.zig.zon` already points at locally
4. `bash platforms/linux/scripts/ci.sh` — `zig build linux linux-app linux-test
   -Dshared` targeted at glibc 2.31, `byakaron --help` / `--version`, smoke test,
   IME integration test against a throwaway Xvfb+ibus-daemon, display-path probe,
   Fcitx5 addon (headers are installed on the runner; same glibc 2.31 ceiling),
   GtkEntry typing through the IBus IM module

`spell.db` is not built on the runner (364 MB). Smoke skips those assertions
when the file is missing; typing and candidates do not need it.

To run the same steps locally:

```bash
bash platforms/linux/scripts/ci.sh
```

## Fcitx5 (optional)

A second IME framework, not a skin over IBus. `platforms/linux/Fcitx5/` is a
C++ `InputMethodEngineV2` that applies the same `Core/composer.c` outcomes as
`Keyboard/engine.c`. Build with `zig build linux-fcitx5` when
`libfcitx5core-dev` is installed (or `PKG_CONFIG_PATH` points at those
headers). That does **not** switch the session to Fcitx5.

Install copies `byakaron.so` plus the addon/inputmethod `.conf` files if the
addon was **rebuilt in that same run** (a leftover `zig-out` copy is not
shipped). The addon is built for glibc 2.31 like the engine. Fcitx5 users then
add **Byakaron** in the Fcitx5 config tool.

## Flatpak (app only)

An IBus engine has to live in `/usr/share/ibus/component` so the session
daemon can spawn it. A sandboxed Flatpak cannot register there, which is why
ibus-avro ships as a `.deb` too. `scripts/package_deb.sh` is the IME artefact.
It emits one package:

- `byakaron_*.deb` — engine, GTK app, GSettings schema, and `spell.db`.
  Typing Bangla and spell-check.

One `apt install` of that file is a complete install. Upgrading from the older
split (`byakaron` + `byakaron-data`) replaces `byakaron-data` automatically.

The settings app is GTK3, so Spelling / Layout / Setup run on
**Ubuntu 20.04, 22.04, and 24.04** — the same releases as the keyboard.

### Installing on Ubuntu

One command installs the keyboard, the GTK app, and spell-check:

```bash
curl -fsSL https://nuhulabs.com/byakaron/install.sh | sudo bash
```

That downloads the `.deb` for this CPU (amd64 or arm64) from the public
[nuhulabs/Byakaron-Assets](https://github.com/nuhulabs/Byakaron-Assets/releases)
releases and runs `apt`. Then **add the input source** (installing the package
is not enough): Settings → Keyboard → Input Sources → **+** → **Bangla** →
**Byakaron (Bangla Phonetic)** → Add. Switch with Super+Space.

To build and share a `.deb` yourself instead:

The keyboard is built for **glibc 2.31**, so it works on **Ubuntu 20.04, 22.04,
and 24.04**. On ARM, see [ARM.md](ARM.md).

```bash
bash platforms/linux/scripts/package_deb.sh
sudo apt install ./platforms/linux/build/byakaron_0.1.9_amd64.deb
```

Use `apt`, not `dpkg -i`. If an older Byakaron `.deb` is already installed
(`byakaron`, `byakaron-app`, or `byakaron-data`), remove it first:
`sudo apt remove byakaron byakaron-app byakaron-data`. Then add the input
source (step above) and switch with Super+Space. If Byakaron is missing from
the Bangla list, log out and back in.

The companion GTK app *can* live in a sandbox:

```bash
bash platforms/linux/scripts/package_flatpak.sh
```

That packs the already-built `byakaron` binary against `org.gnome.Platform`
(used as both runtime and SDK, so `org.gnome.Sdk` is not required). It does
not include the engine or the 364 MB `spell.db`. Manifest:
`Resources/dev.nuhu.labs.Byakaron.json`. The same AppStream metadata used by
the Debian package lives in `Resources/dev.nuhu.labs.Byakaron.metainfo.xml`.

## Desktop hand-test checklist

After installing the engine and adding **Byakaron** as an input source, switch to it with Super+Space and verify `ami` + Space commits `আমি ` in GTK4, Firefox, Chrome, one Qt application, and Cursor or another Electron app. In Cursor/Electron, specifically confirm a pending word is committed before its preedit is hidden. If using Fcitx5, also add Byakaron in the Fcitx5 configuration tool and confirm the same flow.

For Wayland without logging out, run `scripts/gnome_wayland_test.sh` (see [Wayland](#wayland)). A Wayland *login* is still the place to check things the sandbox cannot: candidate-window position, and browsers.

## Known issues

- **Qt apps on Ubuntu 20.04 / 22.04 type a pending word twice on a click**
  (`ami` + click → আমিআমি). Qt's IBus module commits the word itself and does
  not tell the daemon; IBus 1.5.22 / 1.5.26 cannot tell the engine which app
  is focused, and Qt reports the same capabilities as GTK, so the engine has
  no way to treat Qt differently there. The other choice (never let IBus
  commit) would lose or misplace the word in GTK apps and browsers, which are
  most of what people type in. Workaround: press Space before clicking away.
  Fixed on Ubuntu 24.04 (IBus 1.5.29 reports the client name). GTK, Chrome,
  Firefox and Electron are unaffected on all three releases.

## Notes

- `spell.db` is a **local SQLite file**, not a server. It is generated, not
  committed (`*.db` is gitignored). Build it with:
  `bash platforms/linux/scripts/prepare_spell_db.sh`
  That uses the Avro lexicon already in `src/assets/dictionary_macos_sorted.txt`
  (~159k words). Wikipedia n-grams are empty until someone later runs the full
  `word_triplets.csv` export; lookups and SymSpell suggestions still work.
  `install.sh` copies it to `/usr/share/byakaron/spell.db` when the file is
  present. The shareable `.deb` ships it in the same package as the keyboard
  and app, so one file is a complete install. Override the path
  with `BYAKARON_SPELL_DB` for development. The input method types without it;
  only spell-check needs it. Candidates use the compiled-in lexicon.
- `platforms/linux/build/` is generated output and is git-ignored.
