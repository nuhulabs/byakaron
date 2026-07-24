# Byakaron Windows Bangla Keyboard (TSF TIP)

Modern Windows Input Method Editor using the **Text Services Framework**.
After registration it appears in **Win+Space** / the taskbar Input Indicator as
**Byakaron** under Bangla (Bangladesh) — same role as the macOS Input Method.

## Build

From the repo root (Zig 0.17 + MSVC Build Tools required):

```powershell
$env:ZIG_EXE = "<path-to-zig.exe>"   # optional if zig is on PATH
.\platforms\windows\scripts\build_ime.ps1
```

Produces:

- `platforms/windows/Keyboard/bin/x64/Release/ByakaronIME.dll`
- `platforms/windows/Keyboard/stage/` and `platforms/windows/Byakaron/ime/`
  (TIP + `byakaron.dll` Zig FFI)

## Install

Prefer the in-app **keyboard** button (toolbar), or elevated:

```powershell
regsvr32 /s platforms\windows\Keyboard\stage\ByakaronIME.dll
```

Unregister:

```powershell
regsvr32 /u /s "%LOCALAPPDATA%\Byakaron\IME\ByakaronIME.dll"
```

Then: **Settings → Time & language → Language & region → Bangla** and confirm
Byakaron is listed, or switch with **Win+Space**.

## Typing

Avro phonetic Latin → Bangla (Zig engine), matching macOS:

- `ami` → আমি
- Space / Enter commits the composition
- Escape clears
- Backspace edits the Latin buffer
