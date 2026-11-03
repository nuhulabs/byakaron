#!/bin/bash
# Byakaron for Linux — one-command install.
#
# Canonical installer is the website script (Linux + macOS):
#   curl -fsSL https://nuhulabs.com/byakaron/install.sh | bash
#
# This file stays as a thin Linux-only entry for older links and local tests.
# Prefer apps/web/app/public/install.sh when updating install behaviour.
set -euo pipefail

# When this file is the one being curled from an old URL, just run the same
# Linux path as the website script (inlined below so offline copies still work).

REPO="${BYAKARON_REPO:-nuhulabs/Byakaron-Assets}"
DEB_NAME_FOR_ARCH() { echo "byakaron_${1}.deb"; }

die() { echo "error: $*" >&2; exit 1; }

case "$(uname -s)" in
    Linux) ;;
    Darwin) die "this is the Linux installer. For a Mac: curl -fsSL https://nuhulabs.com/byakaron/install.sh | bash" ;;
    *) die "this installer is for Linux (Ubuntu or Debian), not $(uname -s)" ;;
esac

OS_RELEASE="${BYAKARON_OS_RELEASE:-/etc/os-release}"
OS_NAME="Linux"
if [[ -r "$OS_RELEASE" ]]; then
    OS_NAME="$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$OS_RELEASE" | head -n 1)"
    [[ -n "$OS_NAME" ]] || OS_NAME="Linux"
fi

command -v apt-get >/dev/null && command -v dpkg >/dev/null \
    || die "Byakaron is packaged for Ubuntu and Debian (apt). This is $OS_NAME, which has no apt."
command -v curl >/dev/null || die "need curl: sudo apt install curl"

ARCH="$(dpkg --print-architecture)"
KERNEL_CPU="$(uname -m)"
case "$ARCH" in
    amd64) CPU_NAME="Intel/AMD 64-bit (amd64)" ;;
    arm64) CPU_NAME="ARM 64-bit (arm64)" ;;
    armhf|armel)
        hint=""
        [[ "$KERNEL_CPU" == aarch64 ]] && hint=" The processor is 64-bit, but the installed system is 32-bit."
        die "this is a 32-bit ARM system ($ARCH, $OS_NAME).$hint
       Byakaron needs a 64-bit system: Raspberry Pi OS (64-bit) or Ubuntu Desktop arm64,
       on a Raspberry Pi 4 or 5. See https://nuhulabs.com/byakaron" ;;
    i386) die "this is a 32-bit PC system ($OS_NAME). Byakaron needs 64-bit Ubuntu or Debian." ;;
    *) die "unsupported CPU '$ARCH' ($OS_NAME). Byakaron is built for amd64 and arm64." ;;
esac
echo ">>> Detected: $OS_NAME, $CPU_NAME"

deb_name="$(DEB_NAME_FOR_ARCH "$ARCH")"
deb_url="${BYAKARON_DEB_URL:-https://github.com/${REPO}/releases/latest/download/${deb_name}}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
deb="$tmp/byakaron.deb"

echo ">>> downloading $deb_url"
curl -fL --progress-bar -o "$deb" "$deb_url" \
    || die "could not download $deb_url
       publish ${deb_name} on nuhulabs/Byakaron-Assets (public), or set BYAKARON_DEB_URL"

echo ">>> installing (keyboard + app + spell-check)"
export DEBIAN_FRONTEND=noninteractive
was_installed="$(dpkg-query -W -f='${Version}' byakaron 2>/dev/null || true)"
if [[ "${EUID}" -eq 0 ]]; then
    BYAKARON_INSTALLER=1 apt-get install -y "$deb"
else
    sudo env BYAKARON_INSTALLER=1 apt-get install -y "$deb"
fi

now_installed="$(dpkg-query -W -f='${Version}' byakaron 2>/dev/null || true)"
# Shown without the epoch: the .deb is 1:0.1.x so it is newer than the
# old Linux-only 0.2.x; people know the version as 0.1.x.
was_shown="${was_installed#*:}" now_shown="${now_installed#*:}"
if [[ -n "$was_installed" && "$was_installed" == "$now_installed" ]]; then
    echo
    echo "=== Byakaron $now_shown is already the latest ==="
    echo
    exit 0
elif [[ -n "$was_installed" ]]; then
    echo
    echo "=== Byakaron updated: $was_shown -> $now_shown ==="
    echo "  Your input source stays as it is. Switch with Super+Space."
    echo
    exit 0
fi

echo
echo "=== Byakaron $now_shown is installed. Add it as an input source: ==="
if command -v gnome-control-center >/dev/null; then
    echo "  1. Settings -> Keyboard -> Input Sources -> '+'"
    echo "  2. Choose Bangla, then Byakaron (Bangla Phonetic) -> Add"
    echo "  3. Switch with Super+Space and type ami then Space (আমি )"
    echo "  Or open the Byakaron app -> Setup."
    echo "  If it is missing from the Bangla list, log out and back in."
else
    echo "  1. Make IBus start with your desktop (as yourself, not root):"
    echo "       im-config -n ibus      (sudo apt install im-config if missing)"
    echo "     then log out and back in."
    echo "  2. Run ibus-setup -> Input Method -> Add -> Bangla -> Byakaron"
    echo "  3. Switch with Super+Space and type ami then Space (আমি )"
    echo "  Or open the Byakaron app -> Setup."
fi
echo
