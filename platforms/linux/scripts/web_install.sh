#!/bin/bash
# Byakaron for Linux — one-command install.
#
#   curl -fsSL https://nuhulabs.com/byakaron/install.sh | sudo bash
#
# Downloads the matching .deb from GitHub Releases and installs it with apt
# (keyboard, GTK app, spell-check). Adding the input source in Settings is
# still a separate click — the package cannot do that for the user.
set -euo pipefail

REPO="${BYAKARON_REPO:-nuhulabs/byakaron}"
VERSION_FALLBACK="0.1.5"

die() { echo "error: $*" >&2; exit 1; }

if [[ "$(uname -s)" != "Linux" ]]; then
    die "this installer is for Ubuntu/Debian. macOS: https://nuhulabs.com/byakaron"
fi

command -v curl >/dev/null || die "need curl"
command -v apt-get >/dev/null || die "need apt (Ubuntu 20.04, 22.04, or 24.04)"
command -v dpkg >/dev/null || die "need dpkg"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64|arm64) ;;
    *) die "unsupported CPU '$ARCH' — need amd64 or arm64 (64-bit Ubuntu)" ;;
esac

deb_url=""
if [[ -n "${BYAKARON_DEB_URL:-}" ]]; then
    deb_url="$BYAKARON_DEB_URL"
else
    api="https://api.github.com/repos/${REPO}/releases/latest"
    json="$(curl -fsSL -H "Accept: application/vnd.github+json" "$api" 2>/dev/null || true)"
    if [[ -n "$json" ]] && command -v python3 >/dev/null; then
        deb_url="$(printf '%s' "$json" | python3 -c '
import json, sys
arch = sys.argv[1]
try:
    rel = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in rel.get("assets") or []:
    name = a.get("name") or ""
    url = a.get("browser_download_url") or ""
    if name.startswith("byakaron_") and name.endswith("_" + arch + ".deb") and "-data_" not in name:
        print(url)
        break
' "$ARCH" || true)"
    fi
    if [[ -z "$deb_url" ]]; then
        deb_url="https://github.com/${REPO}/releases/latest/download/byakaron_${VERSION_FALLBACK}_${ARCH}.deb"
    fi
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
deb="$tmp/byakaron.deb"

echo ">>> Byakaron for Linux ($ARCH)"
echo ">>> downloading"
curl -fL --progress-bar -o "$deb" "$deb_url" \
    || die "could not download $deb_url
       publish a GitHub release with byakaron_*_${ARCH}.deb, or set BYAKARON_DEB_URL"

echo ">>> installing (keyboard + app + spell-check)"
export DEBIAN_FRONTEND=noninteractive
if [[ "${EUID}" -eq 0 ]]; then
    apt-get install -y "$deb"
else
    sudo apt-get install -y "$deb"
fi

echo
echo "=== Byakaron is installed. Add it as an input source: ==="
echo "  1. Settings -> Keyboard -> Input Sources -> '+'"
echo "  2. Choose Bangla, then Byakaron (Bangla Phonetic) -> Add"
echo "  3. Switch with Super+Space and type ami then Space (আমি )"
echo "  Or open the Byakaron app -> Setup."
echo "  If it is missing from the Bangla list, log out and back in."
echo
