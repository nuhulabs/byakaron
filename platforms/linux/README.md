# Byakaron for Linux

Bangla phonetic input method and companion app for Linux, driven by the same
Zig engine as the macOS and Windows ports through its C ABI (`src/ffi/byakaron.h`).

## How this fits the other platforms

| Layer | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Keyboard / IME | Swift + InputMethodKit | C++ + TSF | **C + IBus** |
| GUI app | SwiftUI | C# WinUI 3 | **C + GTK4 / libadwaita** |
| Engine linkage | static `libbyakaron.a` | shared `byakaron.dll` | **static into the engine; `.so` for the app** |

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
├── App/         GTK4 + libadwaita settings and spell-check app
├── Core/        Shared C glue over byakaron.h, used by App and Keyboard
├── Keyboard/    The IBus engine
├── Resources/   IBus component XML, .desktop entry, icons
├── scripts/     setup_deps.sh, build_zig.sh, smoke.sh, install.sh, uninstall.sh
└── tests/       C ABI + Core smoke test, IBus integration test
```

`Core/` holds the glue that both front-ends need: `transliterator.c` for
latin → Bangla and `autocomplete.c` for candidates. Both hand back plain
`g_malloc`'d memory, so the Zig ownership rule (`byakaron_string_free`) and the
JSON the ABI returns stop there and nothing above them has to know.

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
```

The engine binary links the Zig core statically, so it is self-contained apart
from system IBus and GLib. `-Dshared` still produces `libbyakaron.so`, which is
what the GTK app and distro packaging will consume.

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

Two rules keep the list from getting in the way:

- **Only the number keys select.** Space and Enter always commit what was
  *typed*, never a candidate, so no keystroke can quietly substitute a different
  word. The list is also drawn without a selection highlight, because a
  highlight would imply Space would take it.
- **Digits and punctuation stay out of the buffer.** The core does map them
  (`2024` → ২০২৪, `.` → `।`), but buffering them cannot coexist with selecting
  by number — the same `2` cannot both extend the word and pick the second
  candidate. Typing Bangla numerals therefore needs an explicit mode toggle,
  which belongs with the settings app where a keybinding can be surfaced.

Escape drops the word and the list together rather than dismissing the list
first: a two-stage Escape would mean two different things depending on state the
user can no longer see once the list is gone.

The panel's own paging arrows and mouse clicks work too — the engine implements
the `page_up`, `page_down`, and `candidate_clicked` handlers the panel drives.

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

After installing:

1. Settings → Keyboard → Input Sources → **+**
2. Search "Byakaron" (filed under Bangla) → Add
3. Switch with **Super+Space**

```bash
sudo bash platforms/linux/scripts/uninstall.sh
```

removes everything install.sh added.

## Notes

- `spell.db` is generated, not committed, and cannot currently be built from a
  fresh checkout: `cd packages/data && zig build prepare` needs the `sqlite3`
  CLI *and* `packages/data/export_id/*.csv`, which come from
  `zig build export` over a `word_triplets.csv` corpus that is not in the
  repository. Neither the input method nor its candidate list needs it —
  candidates use the compiled-in lexicon — so only spell-check is waiting on it.
- `platforms/linux/build/` is generated output and is git-ignored.
