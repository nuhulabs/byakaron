# ---------------------------------------------------------------------------
# Build (Debug) and run the WinUI app. Invoked by `zig build run-win`.
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptDir
$RepoRoot = Split-Path -Parent (Split-Path -Parent $WindowsRoot)
$Proj = Join-Path $WindowsRoot "Byakaron\Byakaron.csproj"
$AppImeDir = Join-Path $WindowsRoot "Byakaron\ime"
$KeyboardDir = Join-Path $WindowsRoot "Keyboard"
$StageDir = Join-Path $KeyboardDir "stage"

Write-Host "=== Stage Zig FFI ==="
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "build_zig.ps1")
if ($LASTEXITCODE -ne 0) { throw "build_zig.ps1 failed" }

# Build IME if missing (optional for spell-only; needed for keyboard button).
$ImeDll = Join-Path $KeyboardDir "bin\x64\Release\ByakaronIME.dll"
if (-not (Test-Path $ImeDll)) {
    Write-Host "=== Build ByakaronIME ==="
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "build_ime_msvc.ps1")
    if ($LASTEXITCODE -ne 0) { throw "build_ime_msvc.ps1 failed" }
}

if (Test-Path $ImeDll) {
    $DllSrc = @(
        (Join-Path $WindowsRoot "Byakaron\native\byakaron.dll"),
        (Join-Path $RepoRoot "zig-out\bin\byakaron.dll")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    foreach ($dir in @($StageDir, $AppImeDir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -Force $ImeDll (Join-Path $dir "ByakaronIME.dll")
        if ($DllSrc) { Copy-Item -Force $DllSrc (Join-Path $dir "byakaron.dll") }
    }
}

Write-Host "=== dotnet run ==="
& dotnet run --project $Proj -c Debug -p:Platform=x64 --no-launch-profile
if ($LASTEXITCODE -ne 0) { throw "dotnet run failed" }
