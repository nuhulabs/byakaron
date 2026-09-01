# Byakaron for Linux

Bangla phonetic input method and companion app for Linux, driven by the same
Zig engine as the macOS and Windows ports through its C ABI (`src/ffi/byakaron.h`).

## How this fits the other platforms

| Layer | macOS | Windows | Linux |
| --- | --- | --- | --- |
| Keyboard / IME | Swift + InputMethodKit | C++ + TSF | **C + IBus** |
| GUI app | SwiftUI | C# WinUI 3 | **C + GTK4 / libadwaita** |
| Engine linkage | static `libbyakaron.a` | shared `byakaron.dll` | **shared `libbyakaron.so`** |

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

## Notes

- `spell.db` is generated, not committed. Build it with
  `cd packages/data && zig build prepare`. The input method works without it;
  only spell-check does not.
- `platforms/linux/build/` is generated output and is git-ignored.
