# Byakaron Windows Bangla Keyboard (TSF TIP)

Modern Windows Input Method Editor using the **Text Services Framework**.
After registration it appears in **Win+Space** / the taskbar Input Indicator as
**Byakaron Phonetic** under Bangla (Bangladesh).

## Installer (share this)

From the repo root (Zig 0.17 + .NET 8 SDK + [Inno Setup 6](https://jrsoftware.org/isinfo.php),
e.g. `choco install innosetup`; `-Dwindows-iscc=<path>` if ISCC.exe is not under
Program Files or on PATH):

```powershell
zig build windows
```

Output:

| File | Purpose |
|------|---------|
| `zig-out/pkg/Byakaron-Setup.exe` | **Single installer** — share this |
| `zig-out/bin/Byakaron/` | Unpacked payload (debug / Inno source) |

The installer copies the app, registers the Bangla (Bangladesh) TIP (optional task), and adds Start Menu shortcuts.

Version: `-Dwindows-version=1.2.3`, else `BYAKARON_VERSION`, else 1.0.0.
Byakaron.db is built as by `zig build db`; `-Dspell-db=<path>` stages a prebuilt
one instead, `-Ddb-words=N` a smaller one.

## Development run

```powershell
zig build run-win
```

## IME-only build

Cross-compiled with Zig (x86_64-windows-gnu), so this works from any host:

```sh
zig build windows-ime
```

Produces `zig-out/lib/windows/ime/ByakaronIME.dll` and `byakaron.dll`. `windows`
and `run-win` stage the same pair into `apps/windows/Byakaron/ime/` (and
byakaron.dll + Byakaron.db into `Native/`), which Byakaron.csproj copies next to
the app.

## Manual IME register

Prefer the installer or the in-app **keyboard** button. Elevated:

```powershell
regsvr32 /s "%LOCALAPPDATA%\Byakaron\IME\ByakaronIME.dll"
```

Unregister:

```powershell
regsvr32 /u /s "%LOCALAPPDATA%\Byakaron\IME\ByakaronIME.dll"
```

## Typing

The keyboard is a thin TSF shell over the shared composer in `byakaron.dll`
(`byakaron_composer_*`, see `src/Composer.zig`), so it types exactly like the
other Byakaron keyboards (OmicronLab Avro behaviour):

- `ami` → আমি; the highlighted candidate is shown inline
- Space commits it and a space, Enter commits it (plus a new line with
  "New line on Enter"), Tab and other keys commit it and pass through
- Arrows move the highlight, Page Up/Down change page, 1–9 or a click pick
- Escape drops the word, Backspace edits it

Settings, learned choices and the personal dictionary live in
`%LOCALAPPDATA%\Byakaron` (`settings.json`, `selections.json`,
`user-words.txt`), edited from the Byakaron app's Settings. Spelling
corrections use the installed `native\Byakaron.db` when present.
