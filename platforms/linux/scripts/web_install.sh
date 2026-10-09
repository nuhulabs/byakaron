#!/bin/bash
# Byakaron for Linux — one-command install.
#
#   curl -fsSL https://nuhulabs.com/byakaron/install.sh | sudo bash
#
# Downloads the matching .deb from the public Byakaron-Assets GitHub Releases
# (nuhulabs/byakaron is private, so anonymous curl cannot use that repo) and
# installs it with apt (keyboard, GTK app, spell-check). Adding the input
# source in Settings is still a separate click — the package cannot do that.
set -euo pipefail

REPO="${BYAKARON_REPO:-nuhulabs/Byakaron-Assets}"
VERSION_FALLBACK="0.1.9"

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

# Three ways to find the .deb, most exact first. None needs python3: a stock
# Ubuntu image does not have it, and the old python-only parse fell through to
# VERSION_FALLBACK — a 404 whenever that version was not the latest release.
deb_url=""
if [[ -n "${BYAKARON_DEB_URL:-}" ]]; then
    deb_url="$BYAKARON_DEB_URL"
else
    # 1. The API lists the assets. It is rate-limited to 60 calls an hour per
    #    IP, which a shared office or campus NAT can use up.
    api="https://api.github.com/repos/${REPO}/releases/latest"
    json="$(curl -fsSL -H "Accept: application/vnd.github+json" "$api" 2>/dev/null || true)"
    deb_url="$(printf '%s' "$json" \
        | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | grep -oE 'https://[^"]+/byakaron_[^/"]+_'"$ARCH"'\.deb' \
        | head -n 1 || true)"

    # 2. The web redirect for "latest" names the tag (linux-0.1.5) and is not
    #    rate-limited; the asset name follows from it.
    if [[ -z "$deb_url" ]]; then
        latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "https://github.com/${REPO}/releases/latest" 2>/dev/null || true)"
        tag="${latest##*/tag/}"
        if [[ "$latest" == */tag/* && "$tag" == linux-* ]]; then
            deb_url="https://github.com/${REPO}/releases/download/${tag}/byakaron_${tag#linux-}_${ARCH}.deb"
        fi
    fi

    # 3. Last resort, e.g. github.com unreachable for the lookups above.
    if [[ -z "$deb_url" ]]; then
        deb_url="https://github.com/${REPO}/releases/latest/download/byakaron_${VERSION_FALLBACK}_${ARCH}.deb"
    fi
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
deb="$tmp/byakaron.deb"

echo ">>> Byakaron for Linux ($ARCH)"
echo ">>> downloading $deb_url"
curl -fL --progress-bar -o "$deb" "$deb_url" \
    || die "could not download $deb_url
       publish byakaron_*_${ARCH}.deb on nuhulabs/Byakaron-Assets (public), or set BYAKARON_DEB_URL"

echo ">>> installing (keyboard + app + spell-check)"
export DEBIAN_FRONTEND=noninteractive
# Tells the package's postinst that the steps are printed below, once.
# `sudo env`, because sudo would otherwise drop the variable.
was_installed="$(dpkg-query -W -f='${Version}' byakaron 2>/dev/null || true)"
if [[ "${EUID}" -eq 0 ]]; then
    BYAKARON_INSTALLER=1 apt-get install -y "$deb"
else
    sudo env BYAKARON_INSTALLER=1 apt-get install -y "$deb"
fi

now_installed="$(dpkg-query -W -f='${Version}' byakaron 2>/dev/null || true)"
if [[ -n "$was_installed" && "$was_installed" == "$now_installed" ]]; then
    echo
    echo "=== Byakaron $now_installed is already the latest ==="
    echo
    exit 0
elif [[ -n "$was_installed" ]]; then
    echo
    echo "=== Byakaron updated: $was_installed -> $now_installed ==="
    echo "  Your input source stays as it is. Switch with Super+Space."
    echo
    exit 0
fi

echo
echo "=== Byakaron $now_installed is installed. Add it as an input source: ==="
echo "  1. Settings -> Keyboard -> Input Sources -> '+'"
echo "  2. Choose Bangla, then Byakaron (Bangla Phonetic) -> Add"
echo "  3. Switch with Super+Space and type ami then Space (আমি )"
echo "  Or open the Byakaron app -> Setup."
echo "  If it is missing from the Bangla list, log out and back in."
echo
