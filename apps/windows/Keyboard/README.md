# Byakaron Windows Bangla Keyboard (TSF TIP)

Modern Windows Input Method Editor using the **Text Services Framework**.
After registration it appears in **Win+Space** / the taskbar Input Indicator as
**Byakaron Phonetic** under Bangla (Bangladesh).

## Installer (share this)

From the repo root (Zig 0.17 + MSVC Build Tools + .NET 8 SDK).
First run may install [Inno Setup 6](https://jrsoftware.org/isinfo.php) via winget if needed.

```powershell
zig build windows
```

Output:

| File | Purpose |
|------|---------|
| `zig-out/windows/Byakaron-Setup.exe` | **Single installer** — share this |
| `zig-out/windows/Byakaron/` | Unpacked payload (debug / Inno source) |

The installer copies the app, registers the Bangla (Bangladesh) TIP (optional task), and adds Start Menu shortcuts.

Version: set `BYAKARON_VERSION=1.2.3` before building if you want a custom version stamp.

## Development run

```powershell
zig build run-win
```

## IME-only build

```powershell
$env:ZIG_EXE = "<path-to-zig.exe>"   # optional if zig is on PATH
.\apps\windows\scripts\build_ime.ps1
```

Produces:

- `apps/windows/Keyboard/bin/x64/Release/ByakaronIME.dll`
- `apps/windows/Keyboard/stage/` and `apps/windows/Byakaron/ime/`

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
corrections use the installed `native\spell.db` when present.
