# ---------------------------------------------------------------------------
# Build the Zig FFI as a Windows DLL and stage it for the WinUI app.
#
# Produces:
#   platforms/windows/Byakaron/native/byakaron.dll
#   platforms/windows/Byakaron/native/spell.db   (hardlink/copy from `zig build db` output)
#
# Invoked by `zig build windows` or directly.
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptDir
$RepoRoot = Split-Path -Parent (Split-Path -Parent $WindowsRoot)
$NativeDir = Join-Path $WindowsRoot "Byakaron\native"
$SpellDb = Join-Path $RepoRoot "zig-out\db\spell.db"

$Zig = if ($env:ZIG_EXE) { $env:ZIG_EXE } else { "zig" }
if (-not (Get-Command $Zig -ErrorAction SilentlyContinue) -and -not (Test-Path $Zig)) {
    Write-Error "could not find zig executable (set ZIG_EXE or PATH)"
}

Write-Host ">>> Building Zig FFI shared library (byakaron.dll, ReleaseFast)..."
Push-Location $RepoRoot
try {
    & $Zig build lib "-Doptimize=ReleaseFast" "-Dshared=true"
    if ($LASTEXITCODE -ne 0) { throw "zig build failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}

$DllCandidates = @(
    (Join-Path $RepoRoot "zig-out\bin\byakaron.dll"),
    (Join-Path $RepoRoot "zig-out\lib\byakaron.dll")
)
$Dll = $DllCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Dll) {
    throw "byakaron.dll not found under zig-out (looked in bin/ and lib/)"
}

New-Item -ItemType Directory -Force -Path $NativeDir | Out-Null
Copy-Item -Force $Dll (Join-Path $NativeDir "byakaron.dll")
Write-Host ">>> Staged DLL -> $NativeDir\byakaron.dll"

if (Test-Path $SpellDb) {
    $DestDb = Join-Path $NativeDir "spell.db"
    if ((-not (Test-Path $DestDb)) -or ((Get-Item $SpellDb).LastWriteTime -gt (Get-Item $DestDb).LastWriteTime)) {
        # Prefer hardlink for the ~1GB db; fall back to copy.
        if (Test-Path $DestDb) { Remove-Item -Force $DestDb }
        try {
            New-Item -ItemType HardLink -Path $DestDb -Target $SpellDb | Out-Null
        }
        catch {
            Copy-Item -Force $SpellDb $DestDb
        }
        Write-Host ">>> Staged spell.db -> $DestDb"
    }
    else {
        Write-Host ">>> spell.db already up to date"
    }
}
else {
    Write-Warning "spell.db not found at $SpellDb (run: zig build db)"
}

Write-Host ">>> Windows native assets ready in $NativeDir"
