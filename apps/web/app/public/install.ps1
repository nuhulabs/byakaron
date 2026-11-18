# Byakaron: one-command install (Windows).
#
#   irm https://<host>/install.ps1 | iex
#
# Downloads Byakaron-Setup.exe from nuhulabs/Byakaron-Assets and runs it silently.
# Linux / macOS: use install.sh instead (curl …/install.sh | bash).

$ErrorActionPreference = "Stop"

$Repo = if ($env:BYAKARON_REPO) { $env:BYAKARON_REPO } else { "nuhulabs/Byakaron-Assets" }
$SetupUrl = if ($env:BYAKARON_SETUP_URL) {
    $env:BYAKARON_SETUP_URL
} else {
    "https://github.com/$Repo/releases/latest/download/Byakaron-Setup.exe"
}

function Die([string]$Message) {
    Write-Error "error: $Message"
    exit 1
}

if (-not [Environment]::Is64BitOperatingSystem) {
    Die "Byakaron requires 64-bit Windows 10 or later."
}

# GitHub's latest/ skips prereleases, so while there are only prereleases
# (27.0.0-internal.0, say) it has nothing: take the newest release with the
# installer, as install.sh does.
if (-not $env:BYAKARON_SETUP_URL) {
    try {
        Invoke-WebRequest -Uri $SetupUrl -Method Head -UseBasicParsing | Out-Null
    } catch {
        $Api = "https://api.github.com/repos/$Repo/releases?per_page=20"
        $Preview = (Invoke-RestMethod -Uri $Api -UseBasicParsing) |
            ForEach-Object { $_.assets } |
            Where-Object { $_.name -eq "Byakaron-Setup.exe" } |
            Select-Object -First 1 -ExpandProperty browser_download_url
        if (-not $Preview) { Die "could not find Byakaron-Setup.exe on $Repo (no release has it yet)" }
        Write-Host ">>> no stable release yet: installing the newest preview build"
        $SetupUrl = $Preview
    }
}

$Out = Join-Path ([System.IO.Path]::GetTempPath()) "Byakaron-Setup.exe"
Write-Host ">>> downloading $SetupUrl"
try {
    # -UseBasicParsing avoids IE engine dependency on Server Core / locked-down hosts.
    Invoke-WebRequest -Uri $SetupUrl -OutFile $Out -UseBasicParsing
} catch {
    Die "could not download $SetupUrl (publish Byakaron-Setup.exe on $Repo, or set BYAKARON_SETUP_URL)"
}

Write-Host ">>> running installer"
# Inno Setup: quiet install, keep the default keyboard task checked.
$Args = @("/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES")
$Proc = Start-Process -FilePath $Out -ArgumentList $Args -Wait -PassThru
if ($Proc.ExitCode -ne 0) {
    Die "installer exited with code $($Proc.ExitCode)"
}

Remove-Item -Force $Out -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Byakaron is installed ==="
Write-Host "  Open Byakaron from the Start menu to finish keyboard setup."
Write-Host "  Switch input methods with Win+Space (look for BN / Byakaron)."
Write-Host ""
