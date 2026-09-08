# Byakaron for Linux

Bangla phonetic input method and companion app for Linux, driven by the same
Zig engine as the macOS and Windows ports through its C ABI (`src/ffi/byakaron.h`).

## How this fits the other platforms

| Layer | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Keyboard / IME | Swift + InputMethodKit | C++ + TSF | **C + IBus** |
| GUI app | SwiftUI | C# WinUI 3 | **C + GTK4 / libadwaita** |
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

Fcitx5 is a possible second front-end later; the platform-independent glue in
`Core/` is kept separate from `Keyboard/` so that stays cheap.

## Why C

`libibus` is a GObject/C library, so a C engine includes `<ibus.h>` and
`"byakaron.h"` side by side with no binding layer — the same relationship the
Windows C++ TSF service has to the DLL. It compiles as part of `build.zig`
(`addCSourceFile` + `linkSystemLibrary("ibus-1.0")`), so the port adds no second
build system and no extra language runtime on the per-keystroke path.

## Layout

```
platforms/linux/
├── App/         GTK4 + libadwaita app (main, window, typing, spelling,
│                layout, setup)
├── Core/        Shared C glue over byakaron.h, used by App and Keyboard
├── Keyboard/    The IBus engine
├── Resources/   IBus component XML, .desktop entry, icons
├── scripts/     setup_deps.sh, build_zig.sh, smoke.sh, prepare_spell_db.sh,
│                install.sh, uninstall.sh, package_deb.sh, ci.sh, wayland_probe.sh
└── tests/       C ABI + Core smoke test, IBus integration test
```

`Core/` holds the glue that both front-ends need: `transliterator.c` for
latin → Bangla, `autocomplete.c` for candidates, and `spell.c` for spell.db.
All three hand back plain `g_malloc`'d memory, so the Zig ownership rule
(`byakaron_string_free`) and the JSON the ABI returns stop there and nothing
above them has to know.

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

ziglang.org prunes old dev builds, so fetch it from a community mirror:

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
zig build run-linux-app  # build and run the app
```

The engine binary links the Zig core statically, so it is self-contained apart
from system IBus and GLib. `linux-app` is a separate step on purpose: the engine
must stay buildable on a box that has only `libibus-1.0-dev`, while the app also
needs `libgtk-4-dev` and `libadwaita-1-dev`.

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
| Backspace | Drops one latin character and re-transliterates |
| Space | Commits the Bangla plus the space, in one commit |
| Enter | Commits the word, then lets the application see the Enter |
| Escape | Discards the pending word and its candidates |
| `1`–`9` | Picks that candidate — but only while the list is on screen |
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
  it always types `০`. The list is drawn without a selection highlight, because
  a highlight would imply Space would take it.

Escape drops the word and the list together rather than dismissing the list
first: a two-stage Escape would mean two different things depending on state the
user can no longer see once the list is gone.

The panel's own paging arrows and mouse clicks work too — the engine implements
the `page_up`, `page_down`, and `candidate_clicked` handlers the panel drives.

## The app

A separate process (`byakaron`) from the engine, sharing only `Core/` and the
Zig core underneath. The input method works whether or not it is installed or
running. Four pages behind an `AdwViewSwitcher`:

| Page | What it is for |
| --- | --- |
| **Write** | Compose Bangla here, before the input source is added |
| **Spelling** | Editor with an issue list, red squiggles, and Fix All |
| **Layout** | The Avro key map, as a lookup table |
| **Setup** | Keyboard status, the steps to add it, a typing cheat-sheet |

**Write is a composer, not a two-pane converter.** A converter that
transliterated the whole text on every keystroke would leave the candidate list
decorative, because clicking a Bangla completion cannot be mapped back to the
latin that produced it. Composing a word at a time also makes this an honest
preview of the keyboard: the same Space-commits-what-you-typed rule, the same
1–9 selection, the same Bangla numerals when no list is showing.

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
all it says so and stays out of the way — the other three pages need nothing
installed.

**Setup checks two things, because on Linux they are two steps.** Whether the
IBus component is registered under `/usr/share/ibus/component` (the install),
and whether `byakaron` is in the user's `org.gnome.desktop.input-sources`
(adding it in Settings). That distinction is what separates "run the installer"
from "click **+** in Settings". The GSettings schema is looked up before use,
since `g_settings_new` aborts the process on an unknown schema and that schema
does not exist outside GNOME.

Nothing in the app is configurable yet. The macOS Settings window carries about
fifteen "Coming soon" toggles that do nothing; none of them are reproduced here.

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

The app is installed too when `gtk4` and `libadwaita-1` are present, to
`/usr/bin/byakaron` with a `.desktop` entry — `/usr/bin`, not `/usr/libexec`,
because the user launches it, unlike the engine, which only `ibus-daemon` ever
execs. It is skipped rather than fatal when those libraries are missing, since
the input method is the product. Installing it also fills in the component
XML's `<setup>` element, which is what makes the IBus panel's **Preferences**
button open the app; that element stays empty otherwise, because a setup command
pointing at a missing binary gives a button that silently does nothing.

After installing:

1. Settings → Keyboard → Input Sources → **+**
2. Search "Byakaron" (filed under Bangla) → Add
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

Verified on this X11 session by starting a nested mutter (`mutter --wayland
--headless --no-x11 --virtual-monitor 1280x720`) and launching a GTK4 probe
against it: backend `GdkWaylandDisplay`, IM context id `wayland`, widget
realised. That is the text-input-v3 path. A full "type in Firefox on a Wayland
login" check still wants a Wayland session.

```bash
bash platforms/linux/scripts/wayland_probe.sh
```

## CI

`.github/workflows/linux.yml` runs on every push and pull request:

1. Ubuntu packages (`libibus-1.0-dev`, `libgtk-4-dev`, `libadwaita-1-dev`, `ibus`, `xvfb`)
2. Zig **0.17.0-dev.1422+e863bf3be** via `mlugg/setup-zig` (not master)
3. Clone `ziex` at commit `29f9a85b` to `../../ziex-dev/ziex`, which is what
   `build.zig.zon` already points at locally
4. `bash platforms/linux/scripts/ci.sh` — `zig build linux linux-app linux-test
   -Dshared`, smoke test, IME integration test against a throwaway
   Xvfb+ibus-daemon, display-path probe

`spell.db` is not built on the runner (364 MB). Smoke skips those assertions
when the file is missing; typing and candidates do not need it.

To run the same steps locally:

```bash
bash platforms/linux/scripts/ci.sh
```

## What is not in this port yet

- **Fcitx5.** `Core/` is already the shared glue an addon would use, but a
  working Fcitx5 frontend is its own project (different panel, different
  candidate UI, different install path). IBus covers GNOME/Ubuntu first.
- **Flatpak.** An IBus engine has to live in `/usr/share/ibus/component` so the
  session daemon can spawn it. A sandboxed Flatpak cannot register there, which
  is why ibus-avro ships as a `.deb` too. The `.deb` from
  `scripts/package_deb.sh` is the distribution artefact.

## Notes

- `spell.db` is a **local SQLite file**, not a server. It is generated, not
  committed (`*.db` is gitignored). Build it with:
  `bash platforms/linux/scripts/prepare_spell_db.sh`
  That uses the Avro lexicon already in `src/assets/dictionary_macos_sorted.txt`
  (~159k words). Wikipedia n-grams are empty until someone later runs the full
  `word_triplets.csv` export; lookups and SymSpell suggestions still work.
  `install.sh` copies it to `/usr/share/byakaron/spell.db`. Override the path
  with `BYAKARON_SPELL_DB` for development. The input method types without it;
  only spell-check needs it. Candidates use the compiled-in lexicon.
- `platforms/linux/build/` is generated output and is git-ignored.
