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

Avro phonetic Latin → Bangla (Zig engine):

- `ami` → আমি
- Space / Enter commits the composition
- Escape clears
- Backspace edits the Latin buffer
