# Build ByakaronIME.dll (TSF TIP) + stage install payload next to the WinUI app.
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptDir
$RepoRoot = Split-Path -Parent (Split-Path -Parent $WindowsRoot)
$KeyboardDir = Join-Path $WindowsRoot "Keyboard"
$StageDir = Join-Path $KeyboardDir "stage"
$AppImeDir = Join-Path $WindowsRoot "Byakaron\ime"

$Zig = if ($env:ZIG_EXE) { $env:ZIG_EXE } else { "zig" }

Write-Host ">>> Ensuring Zig FFI shared library..."
Push-Location $RepoRoot
try {
    & $Zig build "-Doptimize=ReleaseFast" "-Dshared=true"
    if ($LASTEXITCODE -ne 0) { throw "zig build -Dshared failed" }
}
finally { Pop-Location }

$DllSrc = @(
    (Join-Path $RepoRoot "zig-out\bin\byakaron.dll"),
    (Join-Path $RepoRoot "zig-out\lib\byakaron.dll")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $DllSrc) { throw "byakaron.dll not found in zig-out" }

Write-Host ">>> Building ByakaronIME with MSVC..."
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "build_ime_msvc.ps1")
if ($LASTEXITCODE -ne 0) { throw "ByakaronIME MSVC build failed" }

$ImeDll = Join-Path $KeyboardDir "bin\x64\Release\ByakaronIME.dll"
if (-not (Test-Path $ImeDll)) { throw "ByakaronIME.dll missing at $ImeDll" }

foreach ($dir in @($StageDir, $AppImeDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -Force $ImeDll (Join-Path $dir "ByakaronIME.dll")
    Copy-Item -Force $DllSrc (Join-Path $dir "byakaron.dll")
}

Write-Host ">>> Staged IME payload:"
Write-Host "    $StageDir"
Write-Host "    $AppImeDir"
Write-Host "Register (elevated): regsvr32 /s `"$StageDir\ByakaronIME.dll`""
