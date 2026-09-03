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
└── tests/       C ABI smoke test
```

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
`bangla → বাংলা`, and a list of autocomplete candidates.

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
discards, and that a multi-word sentence commits correctly.

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
| Escape | Discards the pending word |
| Ctrl/Alt/Super + key | Commits the word, then passes the shortcut through |
| Anything else | Commits the word and is handled by the application |

Space and Enter commit the terminator themselves rather than letting the key
fall through, because `commit_text` travels over D-Bus and a forwarded key is
not guaranteed to arrive after it.

Digits and punctuation are deliberately *not* buffered yet. Avro maps them too,
but swallowing `1` and `.` until the word ends is more surprising than useful
before the candidate window exists.

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

- `spell.db` is generated, not committed. Build it with
  `cd packages/data && zig build prepare`. The input method works without it;
  only spell-check does not.
- `platforms/linux/build/` is generated output and is git-ignored.
