# ---------------------------------------------------------------------------
# Build a single Windows installer:
#   zig-out/windows/Byakaron-Setup.exe
#
# Also stages the unpacked payload at:
#   zig-out/windows/Byakaron/
#
# Invoked by `zig build windows`.
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WindowsRoot = Split-Path -Parent $ScriptDir
$RepoRoot = Split-Path -Parent (Split-Path -Parent $WindowsRoot)
$Proj = Join-Path $WindowsRoot "Byakaron\Byakaron.csproj"
$OutRoot = Join-Path $RepoRoot "zig-out\windows"
$OutDir = Join-Path $OutRoot "Byakaron"
$SetupExe = Join-Path $OutRoot "Byakaron-Setup.exe"
$Iss = Join-Path $WindowsRoot "installer\Byakaron.iss"
$AppImeDir = Join-Path $WindowsRoot "Byakaron\ime"
$KeyboardDir = Join-Path $WindowsRoot "Keyboard"
$StageDir = Join-Path $KeyboardDir "stage"
$AppVersion = if ($env:BYAKARON_VERSION) { $env:BYAKARON_VERSION } else { "1.0.0" }

function Find-ISCC {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
        "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Ensure-InnoSetup {
    $iscc = Find-ISCC
    if ($iscc) { return $iscc }

    Write-Host ">>> Inno Setup 6 not found - installing via winget (one-time)..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        # winget writes to the success stream; discard so it is not returned by this function
        & winget install --id JRSoftware.InnoSetup -e --accept-package-agreements --accept-source-agreements --disable-interactivity *>$null
        $iscc = Find-ISCC
        if ($iscc) { return $iscc }
    }

    Write-Host ">>> winget unavailable or install incomplete - downloading Inno Setup..."
    $tmp = Join-Path $env:TEMP "innosetup-byakaron.exe"
    $url = "https://jrsoftware.org/download.php/is.exe"
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Start-Process -FilePath $tmp -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-" -Wait | Out-Null
    $iscc = Find-ISCC
    if (-not $iscc) {
        throw "Inno Setup 6 (ISCC.exe) not found after install. Install from https://jrsoftware.org/isinfo.php and re-run."
    }
    return $iscc
}

Write-Host "=== 1/5 Zig FFI + spell.db ==="
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "build_zig.ps1")
if ($LASTEXITCODE -ne 0) { throw "build_zig.ps1 failed" }

Write-Host "=== 2/5 ByakaronIME (MSVC) ==="
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "build_ime_msvc.ps1")
if ($LASTEXITCODE -ne 0) { throw "build_ime_msvc.ps1 failed" }

$ImeDll = Join-Path $KeyboardDir "bin\x64\Release\ByakaronIME.dll"
if (-not (Test-Path $ImeDll)) { throw "ByakaronIME.dll missing at $ImeDll" }

$DllSrc = @(
    (Join-Path $RepoRoot "zig-out\bin\byakaron.dll"),
    (Join-Path $RepoRoot "zig-out\lib\byakaron.dll"),
    (Join-Path $WindowsRoot "Byakaron\native\byakaron.dll")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $DllSrc) { throw "byakaron.dll not found for IME staging" }

foreach ($dir in @($StageDir, $AppImeDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -Force $ImeDll (Join-Path $dir "ByakaronIME.dll")
    Copy-Item -Force $DllSrc (Join-Path $dir "byakaron.dll")
}

Write-Host "=== 3/5 dotnet publish (win-x64, self-contained) ==="
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK not found on PATH"
}

New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
if (Test-Path $OutDir) {
    Remove-Item -Recurse -Force $OutDir
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

& dotnet publish $Proj `
    -c Release `
    -r win-x64 `
    -p:Platform=x64 `
    --self-contained true `
    -p:WindowsAppSDKSelfContained=true `
    -p:PublishTrimmed=false `
    -p:PublishReadyToRun=true `
    -o $OutDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

$required = @(
    (Join-Path $OutDir "Byakaron.exe"),
    (Join-Path $OutDir "byakaron_ffi.dll"),
    (Join-Path $OutDir "ime\ByakaronIME.dll"),
    (Join-Path $OutDir "ime\byakaron.dll")
)
foreach ($f in $required) {
    if (-not (Test-Path $f)) { throw "Publish payload missing: $f" }
}
if (-not (Test-Path (Join-Path $OutDir "native\spell.db"))) {
    Write-Warning "native\spell.db missing - spell check will not work until spell.db is staged"
}

Write-Host "=== 4/5 Inno Setup (single installer) ==="
if (-not (Test-Path $Iss)) { throw "Missing installer script: $Iss" }
$iscc = Ensure-InnoSetup
Write-Host ">>> Using ISCC: $iscc"

# ISCC wants forward slashes or escaped paths in /D defines
$publishDirDef = $OutDir -replace '\\', '/'
$outputDirDef = $OutRoot -replace '\\', '/'

if (Test-Path $SetupExe) { Remove-Item -Force $SetupExe }

& $iscc `
    "/DPublishDir=$publishDirDef" `
    "/DOutputDir=$outputDirDef" `
    "/DAppVersion=$AppVersion" `
    $Iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit $LASTEXITCODE)" }
if (-not (Test-Path $SetupExe)) { throw "Expected installer not found: $SetupExe" }

Write-Host "=== 5/5 Done ==="
$setup = Get-Item $SetupExe
Write-Host ""
Write-Host ">>> Single installer ready to share:"
Write-Host "    $($setup.FullName)"
Write-Host ("    Size: {0:N1} MB" -f ($setup.Length / 1MB))
Write-Host "    Unpacked payload (optional): $OutDir"
