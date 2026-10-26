#!/bin/bash
# Byakaron for Linux — one-command install.
#
#   curl -fsSL https://nuhulabs.com/byakaron/install.sh | sudo bash
#
# Downloads the matching .deb from the public Byakaron-Assets GitHub Releases
# (nuhulabs/byakaron may be private) and installs it with apt (keyboard, GTK
# app, spell-check). Adding the input source in Settings is still a separate
# click — the package cannot do that.
set -euo pipefail

REPO="${BYAKARON_REPO:-nuhulabs/Byakaron-Assets}"
VERSION_FALLBACK="0.1.0"

die() { echo "error: $*" >&2; exit 1; }

# One command for every supported computer: the CPU is detected here and the
# matching .deb (amd64 or arm64) is installed. install-amd64.sh and
# install-arm64.sh on the website are copies of this file, so links shared
# while the site had one command per CPU still work on any computer.

case "$(uname -s)" in
    Linux) ;;
    Darwin) die "this is the Linux installer. For a Mac, download Byakaron for macOS: https://nuhulabs.com/byakaron" ;;
    *) die "this installer is for Linux (Ubuntu or Debian), not $(uname -s)" ;;
esac

# Which Linux, for the messages. BYAKARON_OS_RELEASE is for the tests.
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
        # Raspberry Pi OS (32-bit) runs a 32-bit system even on a 64-bit Pi.
        hint=""
        [[ "$KERNEL_CPU" == aarch64 ]] && hint=" The processor is 64-bit, but the installed system is 32-bit."
        die "this is a 32-bit ARM system ($ARCH, $OS_NAME).$hint
       Byakaron needs a 64-bit system: Raspberry Pi OS (64-bit) or Ubuntu Desktop arm64,
       on a Raspberry Pi 4 or 5. See https://nuhulabs.com/byakaron" ;;
    i386) die "this is a 32-bit PC system ($OS_NAME). Byakaron needs 64-bit Ubuntu or Debian." ;;
    *) die "unsupported CPU '$ARCH' ($OS_NAME). Byakaron is built for amd64 and arm64." ;;
esac
echo ">>> Detected: $OS_NAME, $CPU_NAME"

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

    # 2. The web redirect for "latest" names the tag (v0.1.0) and is not
    #    rate-limited; the asset name follows from it.
    if [[ -z "$deb_url" ]]; then
        latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "https://github.com/${REPO}/releases/latest" 2>/dev/null || true)"
        tag="${latest##*/tag/}"
        if [[ "$latest" == */tag/* && "$tag" == v* ]]; then
            deb_url="https://github.com/${REPO}/releases/download/${tag}/byakaron_${tag#v}_${ARCH}.deb"
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
if command -v gnome-control-center >/dev/null; then
    echo "  1. Settings -> Keyboard -> Input Sources -> '+'"
    echo "  2. Choose Bangla, then Byakaron (Bangla Phonetic) -> Add"
    echo "  3. Switch with Super+Space and type ami then Space (আমি )"
    echo "  Or open the Byakaron app -> Setup."
    echo "  If it is missing from the Bangla list, log out and back in."
else
    # Raspberry Pi OS, KDE, Xfce, ...: no GNOME Settings; IBus has its own.
    echo "  1. Make IBus start with your desktop (as yourself, not root):"
    echo "       im-config -n ibus      (sudo apt install im-config if missing)"
    echo "     then log out and back in."
    echo "  2. Run ibus-setup -> Input Method -> Add -> Bangla -> Byakaron"
    echo "  3. Switch with Super+Space and type ami then Space (আমি )"
    echo "  Or open the Byakaron app -> Setup."
fi
echo
