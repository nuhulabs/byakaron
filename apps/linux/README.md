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

Fcitx5 is a possible second front-end over the same Zig composer.
IBus remains the GNOME/Ubuntu default.

## Why C

`libibus` is a GObject/C library, so a C engine includes `<ibus.h>` and
`"byakaron.h"` side by side with no binding layer — the same relationship the
Windows C++ TSF service has to the DLL. It compiles as part of `build.zig`
(`addCSourceFile` + `linkSystemLibrary("ibus-1.0")`), so the port adds no second
build system and no extra language runtime on the per-keystroke path.

## Layout

```
apps/linux/
├── App/         GTK3 app (main, window, spelling, layout, setup)
├── Core/        Shared C glue over byakaron.h (composer glue, spell, prefs)
│                — IBus, Fcitx5, and the app all use this
├── Keyboard/    The IBus engine (thin shell over the Zig composer)
├── Fcitx5/      Optional Fcitx5 addon (same composer; needs libfcitx5core-dev)
├── Resources/   IBus component XML, GSettings schema, .desktop, icons, Flatpak manifest
│                (the build, install, packaging and CI steps are `zig build`
│                 steps: see src/build/linux.zig)
└── tests/       C ABI + Core smoke test, IBus integration test, Wayland probes
```

The keyboard itself — latin buffer, Avro's candidates, highlight, paging,
learning, the personal dictionary, spelling corrections and settings — is the
Zig `Composer` (`src/Composer.zig`) behind the `byakaron_composer_*` ABI, the
same on every platform. `Core/` holds only what Linux adds: `composer.c` maps
X11 keysyms to composer keys, finds the data directory and Byakaron.db, migrates
the old GSettings keys into `settings.json` once, and reads the JSON word lists
the ABI returns; `spell.c` wraps Byakaron.db for the app's Spelling page; `prefs.c`
opens the GSettings schema (now only the Qt click fix). IBus and Fcitx5 are
thin shells over the composer, so they cannot drift from each other or from
macOS, Windows, Android and the web.

The two binaries share `Core/` as source and each links its own static copy of
the Zig core. A single `libbyakaron.so` would save ~7 MB of the download, at the
cost of a SONAME, an `ldconfig` trigger and an ABI promise this version is not
in a position to make; `-Dshared` still builds the `.so` for anyone who wants
to link it.

## Getting set up

### 1. System packages

```bash
sudo zig build linux-deps              # IBus, GTK3 IM module, glib-compile-schemas
sudo zig build linux-deps -- --test    # + compiler and -dev packages for the tests
```

Building needs no `-dev` packages: `zig build linux` (IBus engine + GTK app)
compiles against a pinned Ubuntu 24.04 sysroot (IBus, GLib, GTK 3 headers and
libraries, SHA-256 checked) that the build downloads and caches itself,
targeting glibc 2.31 so the binaries run on Ubuntu 20.04 and newer. The same
build works from macOS or Windows (`-Dlinux-arch=aarch64` for ARM). For an
offline or distro build, `-Dlinux-system-libs=true` links the system libraries
through pkg-config instead.

### 2. Zig

Use Zig **0.17.0**, pinned in the repository's `.tool-versions`
(<https://ziglang.org/download/>). On **ARM64** (Raspberry Pi / Ubuntu
`aarch64`), see [ARM.md](ARM.md).

```bash
V=0.17.0
curl -fSL -o /tmp/zig.tar.xz "https://ziglang.org/download/$V/zig-x86_64-linux-$V.tar.xz"
tar -C ~/.local -xf /tmp/zig.tar.xz
ln -sfn ~/.local/zig-x86_64-linux-$V/zig ~/.local/bin/zig
```

All other dependencies (ziex, SQLite, the sysroot packages) are fetched by
`zig build` from `build.zig.zon`.

### 3. Verify the engine

```bash
zig build linux-smoke
```

This builds the Zig core and calls it from C. Expect `ami → আমি`,
`bangla → বাংলা`, the keysym mapping (keypad keys, modifier-only keys not
sent), a few keystrokes through the composer exactly as the IME shells send
them (preedit = highlighted candidate, Space commits it, arrows wrap, Enter
commits only), settings and personal-dictionary round trips, and the JSON
word-list parser including the inputs it must *reject*. The keyboard's
behaviour itself is tested in Zig (`zig build test`, `src/Composer.zig`).

## Building and running the input method

```bash
zig build linux          # -> zig-out/bin/{byakaron-ibus,byakaron}
zig build linux-app      # alias for `linux`
zig build linux-fcitx5   # -> zig-out/lib/fcitx5/byakaron.so  (optional)
zig build run-linux-app  # build and run the app
zig build linux-test     # -> zig-out/bin/byakaron-ime-test
zig build linux-wayland  # -> zig-out/bin/byakaron-wayland-{probe,type}  (optional, needs libgtk-4-dev)
```

The engine binary links the Zig core statically, so it is self-contained apart
from system IBus and GLib at runtime. GTK3 3.24 is on Ubuntu 20.04, 22.04, and
24.04. `linux-fcitx5` is a separate step: it builds against the host's
`libfcitx5core-dev` (it is not in the pinned sysroot), which a GNOME box does
not have, and installing those headers does not switch the session's input
method.

### Development run

```bash
zig build run-linux
```

Registers the engine with the *running* `ibus-daemon` straight from the build
tree — nothing is copied into `/usr`, and the registration disappears when the
process exits. While it runs, `ibus engine byakaron` switches to it and
`ibus engine xkb:us::eng` switches back.

Permanent installation (so the engine survives a reboot and shows up in
Settings → Keyboard → Input Sources) is `zig build install-linux` (below).

### Integration test

```bash
zig build linux-ci
```

(`linux-ci` starts a private Xvfb + `ibus-daemon` when it can, and runs this
test against it together with the other checks; `zig build run-linux` is the
way to register the engine yourself.)

Starts a throwaway engine, drives it through a *private* IBus input context, and
shuts it down. Because the context is private, the desktop's own input source is
never touched. It asserts the preedit while typing, that Backspace
re-transliterates from the latin buffer, that Space commits, that Escape
discards, that a multi-word sentence commits correctly, and that the candidate
list appears, selects by number, wraps with the arrows, and pages. It runs the
engine on a throwaway `BYAKARON_DATA_DIR`, so the user's settings, learned
choices and personal words are never touched.

The test claims `IBUS_CAP_LOOKUP_TABLE` so the daemon routes candidates to it;
without that capability the table goes to the desktop panel and a client never
sees it.

## How the engine works

Every keystroke goes to the Zig composer (`byakaron_composer_key`), which owns
all of the behaviour below; the IBus engine and the Fcitx5 addon map the X11
keysym to a composer key (keypad digits, Enter, Space, arrows and pages count
as their main-keyboard twins), insert the text it commits, and redraw its
state. Modifier-only keys (Shift, Caps Lock, AltGr, Num Lock) are never sent,
so Shift in `bhalO` stays in the word.

The **latin text the user typed is the single source of truth**: every
keystroke re-runs Avro on the whole buffer. Transliteration is contextual — a
later keystroke can change a glyph already on screen, and one conjunct can span
several latin characters — so Backspace drops one *latin* character and re-runs
the word rather than editing the Bangla.

The inline (preedit) text is the **highlighted candidate**, as in OmicronLab
Avro / iAvro, and the list opens on Avro's preselected one (the one chosen last
time for that input, else the first).

| Key | Behaviour |
| --- | --- |
| `a`–`z`, `A`–`Z` | Appended to the latin buffer; candidates and preedit update |
| `0`–`9` | Bangla numerals (`1` → `১`, `2024` → `২০২৪`) with **Bangla digits** on, else 0–9 typed by the app; `1`–`9` pick a candidate while the list is on screen |
| `.` `,` `:` `$` `^` backtick and other printable ASCII | Appended; Avro maps `.` → `।`, `:` → `ঃ`, `$` → `৳`, `^` → `ঁ` |
| Backspace | Drops one latin character and re-transliterates |
| Space | Commits the highlighted candidate plus the space, in one commit |
| Enter | Commits the highlighted candidate only (Enter consumed); with **New line on Enter** it also reaches the app |
| Escape | Discards the pending word and its candidates |
| `1`–`9` | Picks that candidate on the current page |
| Down / Right, Up / Left | Moves the highlight, wrapping from the last candidate to the first and back, across pages. With **Remember my choices** every move is learned, in `~/.local/share/byakaron/selections.json`. Without a list the arrows commit the word and move the caret as usual |
| Page Up / Page Down | Turns the candidate page (wrapping) while the list is on screen |
| Tab, Ctrl/Alt/Super + key, anything else | Commits the highlighted candidate, then the key reaches the application |

Space commits its own space rather than letting the key fall through, because
`commit_text` travels over D-Bus and a forwarded key is not guaranteed to
arrive after it. The engine always commits before hiding the preedit:
Electron/Monaco treats HidePreeditText as cancel.

## Candidates

Avro's own list for the latin typed so far (autocorrect, dictionary words,
suffix forms, the plain transliteration), then personal-dictionary words that
start with the transliteration, then spelling corrections when Avro found no
dictionary word. The lexicon is compiled into the binary, so candidates work
with nothing installed. **Word suggestions** off is phonetic mode: the word is
transliterated exactly and no list is shown.

The lookup table only ever holds the **current page** (`candidates_per_page`,
3–9, default 9); the composer pages, wraps and remembers. The panel's own
paging arrows, cursor buttons and mouse clicks are forwarded to the composer as
Page Up/Down, Up/Down and `byakaron_composer_pick`.

Escape drops the word and the list together rather than dismissing the list
first: a two-stage Escape would mean two different things depending on state the
user can no longer see once the list is gone.

### Spelling corrections

When Avro's list is just the plain transliteration, the word is probably
misspelled (`sonar` → সনার, `jibon` → জিবন), so up to three corrections from
Byakaron.db follow it. A lookup can take ~150 ms on a cold disk cache, so the
composer does it on a worker thread; when the results arrive it calls back, and
the engine hops to its main loop (`g_idle_add` in IBus, the Fcitx5 event
dispatcher), refreshes the composer and redraws.

Byakaron.db is `$BYAKARON_SPELL_DB` or `/usr/share/byakaron/Byakaron.db`; without it
nothing changes. **Spelling corrections** turns it off.

### Personal dictionary

Words the user marks as correct live in
`~/.local/share/byakaron/user-words.txt`, next to `settings.json` and
`selections.json` (the data directory is `$XDG_DATA_HOME/byakaron`;
`BYAKARON_DATA_DIR` overrides it for tests). Everything goes through the
composer's `byakaron_userdict_*`:

- **App:** "Add to Dictionary" next to Ignore in the Spelling page (Ignore
  still lasts only until the app closes), and *Personal Dictionary…* in the
  main menu (or Settings → **Manage…**) to add a word by hand or remove one.
  Saved words are never flagged.
- **Keyboard:** saved words that start with what is being typed are suggested
  after Avro's candidates, and a saved word is never offered corrections. The
  composer re-reads the data directory when a word starts, so a word added in
  the app works in the keyboard without restarting either.

The app-only Flatpak has its own data directory, so its dictionary is not the
keyboard's.

## The app

A separate process (`byakaron`) from the engine, sharing only `Core/` and the
Zig core underneath. The input method works whether or not it is installed or
running. Four pages, reached from the header-bar menu; the window opens on
**Spelling** and the header title names the current page. `byakaron --page=setup`
opens Setup (that is what the IBus panel **Preferences** button runs);
`--page=settings` opens Settings. *Personal Dictionary…* in the menu opens the
saved-word list.

| Page | What it is for |
| --- | --- |
| **Spelling** | Editor with an issue list, red squiggles, and Fix All |
| **Layout** | The Avro key map, as a lookup table |
| **Setup** | Keyboard status, the steps to add it, a typing cheat-sheet |
| **Settings** | The keyboard's switches and the personal dictionary |

**Spelling checks per word, not with `byakaron_spell_check`.** The bulk call
returns a JSON array of tokens with nested suggestion objects; the app already
has to know each word's position in the buffer to underline it, so it tokenises
locally and calls `byakaron_spell_is_correct` per word — which is what the macOS
and Windows apps do too. Only Bengali-block runs are checked, so latin,
punctuation and emoji are left alone rather than reported as misspelled, and
Bangla digits are skipped because `২০২৪` is not a misspelling.

Suggestions use plain `byakaron_spell_suggest`, not the `_ctx` variant: context
ranking reads bigram and trigram tables that the locally built `Byakaron.db` has
empty, so passing neighbours would cost two queries per word for identical
output. Worth revisiting when the n-grams exist.

`Byakaron.db` is 364 MB, so it opens on a worker thread. The window paints
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

**Settings live in `settings.json`**, shared with every Byakaron platform
(`src/Composer/Settings.zig`). The app opens its own composer on the keyboard's
data directory and writes them with `byakaron_settings_set`; the IBus engine
and the Fcitx5 addon pick them up at their next word, with no restart and no
IPC.

| Setting | `settings.json` field | Default |
| --- | --- | --- |
| **Word suggestions** — off is phonetic mode: exact transliteration, no list | `suggestions` | on |
| **Spelling corrections** (see [Spelling corrections](#spelling-corrections)) | `spelling_corrections` | on |
| **Remember my choices** — the candidate picked for an input is highlighted first next time | `learn_choices` | on |
| **Bangla digits** — off keeps 0–9 outside a word | `bangla_digits` | on |
| **New line on Enter** — Enter commits the word and also starts a new line | `newline_on_enter` | off |
| **Suggestion list** — Horizontal / Vertical | `candidate_orientation` | horizontal |
| **Suggestions per page** — 3–9 | `candidates_per_page` | 9 |

The Settings page also shows the saved-word count with **Manage…** for the
personal dictionary.

One Linux-only switch stays in GSettings (`dev.nuhu.labs.Byakaron`), shown
under **Compatibility** when the schema is installed:

| Switch | Key | Default |
| --- | --- | --- |
| **Qt apps: type a word once on click** — older IBus only (Ubuntu 20.04/22.04): IBus never commits the pending word itself, so Qt types it once; GTK apps and browsers then drop a word still being typed if you click away before Space. Ignored on IBus 1.5.27+ | `qt-click-fix` | off |

**Migration.** The first composer to start without a `settings.json` (the
keyboard or the app) copies the old GSettings keys into it once:
`suggestions = !phonetic-only`, `spelling_corrections = spelling-suggestions`,
`bangla_digits = bangla-digits`, `candidate_orientation` from
`candidates-horizontal`. Those keys stay in the schema, marked deprecated, only
so they can still be read for that; nothing else reads them.

## Installing permanently

```bash
zig build                                              # warm the cache as your user first
sudo -E zig build install-linux                        # add -Dlinux-install-db to build and install Byakaron.db
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
sudo zig build uninstall-linux
```

removes everything `install-linux` added.

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

`zig build linux-wayland-e2e` (`src/build/linux.zig wayland-e2e`) starts a **private** `gnome-shell --headless
--wayland` (own D-Bus, dconf, runtime dir and ibus-daemon, input source set to
Byakaron) next to the running desktop, opens GTK3 and GTK4 windows natively on
it, and types through `org.gnome.Mutter.RemoteDesktop`. Those keys take the
same path as a keyboard on an "Ubuntu on Wayland" login: text-input-v3 →
GNOME Shell → IBus → `byakaron-ibus`. Five checks per toolkit: `ami bangla `,
Shift (`bhalO.` → ভালো।), Bangla numerals, picking candidate 2, and a click
while a word is pending (committed once). Switching the input source to
English makes every check fail, so the test does measure the engine.

```bash
zig build linux-wayland-e2e   # GTK3 + GTK4, 10 checks
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

`zig build linux-ci` runs the quick nested-mutter probes from the
`linux-wayland` binaries (`wayland_probe`, `wayland_type`).

## CI

`.github/workflows/ci.yml` runs on every branch push and pull request, on
`ubuntu-latest` (amd64) and `ubuntu-24.04-arm` (arm64):

1. `zig build linux-deps -- --test` plus `libfcitx5core-dev`, `xvfb`, `appstream`, …
2. Zig **0.17.0** via `mlugg/setup-zig`
3. `zig build linux-ci` — builds `linux`, `linux-test`, the smoke test and
   (when the headers exist) `linux-fcitx5` / `linux-wayland` against the
   pinned sysroot (glibc 2.31), then checks the glibc ceiling, `byakaron --help` / `--version`,
   smoke test, IME integration test against a throwaway Xvfb+ibus-daemon,
   display-path probe, Fcitx5 addon (system headers; same glibc 2.31
   ceiling), GtkEntry typing through the IBus IM module

`Byakaron.db` is not built there. Smoke skips those assertions when the file is
missing; typing and candidates do not need it.

A second job, **GNOME Wayland typing**, installs `gnome-shell` and runs
`zig build linux-wayland-e2e` (see [Wayland](#wayland)): GTK3 and GTK4 apps
on a headless GNOME Shell, typed into through `org.gnome.Mutter.RemoteDesktop`.
On the runner GNOME Shell does not give a new window keyboard focus, so the test
clicks into the window before typing, as a user would.

`.github/workflows/cd.yml` runs on every push to `main`: it builds `Byakaron.db`
once (cached on its inputs), packages, installs and types through both `.deb`s,
and runs the website installer in clean Ubuntu 20.04–26.04 / Debian 12–13
containers. `.github/workflows/release.yml` runs the same for a `linux-*` tag or
a published release (see Releasing).

To run the same steps locally:

```bash
zig build linux-ci
zig build linux-wayland-e2e   # needs gnome-shell
zig build linux-install-test  # the local .deb in clean Ubuntu/Debian containers (Docker)
```

## Releasing

Releases are built and published by GitHub Actions (`release.yml`, with
`cd.yml` doing the Linux part): CI runs `zig build package-linux` on an amd64
and an arm64 runner, installs and types through each `.deb`, and attaches them
to the release. See [RELEASING.md](../../RELEASING.md) for the steps. There is
no local release script.

Bump the version by hand before tagging: `.version` in `build.zig.zon` (the
`.deb` version), `BYK_APP_VERSION` in `App/app.h`, `<version>` in
`Resources/byakaron.xml.in`, and a
`<release>` entry in the AppStream metainfo.

The website installer is `apps/linux/web_install.sh`. Copy it by hand to
`install.sh` in the nuhulabs.com repo (`app/public/byakaron`), plus the same
file as `install-amd64.sh` and `install-arm64.sh` for links shared earlier. The
page itself needs no version bump: the installer fetches the latest release.
`bash apps/linux/tests/web_install_test.sh` checks what it decides on different
systems.

## Fcitx5 (optional)

A second IME framework, not a skin over IBus. `apps/linux/Fcitx5/` is a
C++ `InputMethodEngineV2` over the same Zig composer as `Keyboard/engine.c`
(one composer for the addon; a pending word is committed when its input
context is reset or loses focus, since Fcitx5 does not commit the preedit by
itself). Build with `zig build linux-fcitx5` when
`libfcitx5core-dev` is installed (or `PKG_CONFIG_PATH` points at those
headers). That does **not** switch the session to Fcitx5.

Install copies `byakaron.so` plus the addon/inputmethod `.conf` files if the
addon was **rebuilt in that same run** (a leftover `zig-out` copy is not
shipped). The addon is built for glibc 2.31 like the engine. Fcitx5 users then
add **Byakaron** in the Fcitx5 config tool.

## Flatpak (app only)

An IBus engine has to live in `/usr/share/ibus/component` so the session
daemon can spawn it. A sandboxed Flatpak cannot register there, which is why
ibus-avro ships as a `.deb` too. `zig build package-linux` is the IME artefact.
It emits one package:

- `byakaron_*.deb` — engine, GTK app, GSettings schema, and `Byakaron.db`.
  Typing Bangla and spell-check.

One `apt install` of that file is a complete install. Upgrading from the older
split (`byakaron` + `byakaron-data`) replaces `byakaron-data` automatically.

The settings app is GTK3, so Spelling / Layout / Setup run on
**Ubuntu 20.04, 22.04, 24.04 and 26.04, and Debian 12 and 13** — the same
releases as the keyboard.

### Installing on Ubuntu

One command installs the keyboard, the GTK app, and spell-check. The website
shows the one for the computer's processor (an Intel / AMD | ARM switch):

```bash
curl -fsSL https://nuhulabs.com/byakaron/install-amd64.sh | sudo bash   # Intel / AMD
curl -fsSL https://nuhulabs.com/byakaron/install-arm64.sh | sudo bash   # ARM
curl -fsSL https://nuhulabs.com/byakaron/install.sh | sudo bash         # either: detects it
```

Each per-CPU script stops with the right command if run on the other kind of
computer. They download the `.deb` from the public
[nuhulabs/byakaron](https://github.com/nuhulabs/byakaron/releases)
releases and runs `apt`. Then **add the input source** (installing the package
is not enough): Settings → Keyboard → Input Sources → **+** → **Bangla** →
**Byakaron (Bangla Phonetic)** → Add. Switch with Super+Space.

To build and share a `.deb` yourself instead:

The keyboard is built for **glibc 2.31**, so it works on **Ubuntu 20.04, 22.04,
24.04 and 26.04, and Debian 12 and 13**. On ARM, see [ARM.md](ARM.md).

```bash
zig build package-linux      # alias: linux-deb; builds Byakaron.db too
sudo apt install ./zig-out/pkg/byakaron_<version>_amd64.deb
```

Use `apt`, not `dpkg -i`. If an older Byakaron `.deb` is already installed
(`byakaron`, `byakaron-app`, or `byakaron-data`), remove it first:
`sudo apt remove byakaron byakaron-app byakaron-data`. Then add the input
source (step above) and switch with Super+Space. If Byakaron is missing from
the Bangla list, log out and back in.

The companion GTK app *can* live in a sandbox:

```bash
zig build package-linux-flatpak
```

That packs the already-built `byakaron` binary against `org.gnome.Platform`
(used as both runtime and SDK, so `org.gnome.Sdk` is not required). It does
not include the engine or the 364 MB `Byakaron.db`. Manifest:
`Resources/dev.nuhu.labs.Byakaron.json`. The same AppStream metadata used by
the Debian package lives in `Resources/dev.nuhu.labs.Byakaron.metainfo.xml`.

## Desktop hand-test checklist

After installing the engine and adding **Byakaron** as an input source, switch to it with Super+Space and verify `ami` + Space commits `আমি ` in GTK4, Firefox, Chrome, one Qt application, and Cursor or another Electron app. In Cursor/Electron, specifically confirm a pending word is committed before its preedit is hidden. If using Fcitx5, also add Byakaron in the Fcitx5 configuration tool and confirm the same flow.

For Wayland without logging out, run `zig build linux-wayland-e2e` (see [Wayland](#wayland)). A Wayland *login* is still the place to check things the sandbox cannot: candidate-window position, and browsers.

## Known issues

- **Qt apps on Ubuntu 20.04 / 22.04 type a pending word twice on a click**
  (`ami` + click → আমিআমি). Qt's IBus module commits the word itself and does
  not tell the daemon; IBus 1.5.22 / 1.5.26 cannot tell the engine which app
  is focused, and Qt reports the same capabilities as GTK, so the engine has
  no way to treat Qt differently there. The other choice (never let IBus
  commit) would lose or misplace the word in GTK apps and browsers, which are
  most of what people type in. Workaround: press Space before clicking away,
  or, on a mostly-Qt desktop (KDE), turn on **Settings → Qt apps: type a word
  once on click** (then GTK apps drop an unfinished word on click instead).
  Measured on 22.04 in clean containers: Qt `ami` + click gives আমি with the
  switch on, আমিআমি off; GTK gives আমি off, nothing on.
  Fixed on Ubuntu 24.04 (IBus 1.5.29 reports the client name). GTK, Chrome,
  Firefox and Electron are unaffected on all three releases.

## Notes

- `Byakaron.db` is a **local SQLite file**, not a server. It is generated, not
  committed (`*.db` is gitignored). Build it with `zig build db`, which
  downloads the bnwiki dump and merges the Avro lexicon into a Wikipedia
  dictionary with bigram/trigram tables (written to `zig-out/db/Byakaron.db`).
  `zig build install-linux` copies it to `/usr/share/byakaron/Byakaron.db` when the file is
  present. The shareable `.deb` ships it in the same package as the keyboard
  and app, so one file is a complete install. Override the path
  with `BYAKARON_SPELL_DB` for development. The input method types without it;
  only spell-check needs it. Candidates use the compiled-in lexicon.
- Deb staging lives under `apps/linux/build/` (git-ignored); the shareable
  `.deb` is written to `zig-out/pkg/`.
