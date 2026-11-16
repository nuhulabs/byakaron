#!/bin/bash
# Byakaron for Linux — one-command install (Ubuntu, Debian, Arch).
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
ASSETS="https://github.com/${REPO}/releases/latest/download"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "need $1"; }

case "$(uname -s)" in
    Linux) ;;
    Darwin) die "this is the Linux installer. For a Mac: curl -fsSL https://nuhulabs.com/byakaron/install.sh | bash" ;;
    *) die "this installer is for Linux (Ubuntu, Debian or Arch), not $(uname -s)" ;;
esac

# The same Linux code as apps/web/app/public/install.sh: keep them identical.
# One command for every Linux Byakaron is packaged for: the .deb with apt on
# Ubuntu, Debian and Raspberry Pi OS, the Arch package with pacman on Arch
# Linux and the systems built on it (Manjaro, EndeavourOS, …).
install_linux() {
    OS_RELEASE="${BYAKARON_OS_RELEASE:-/etc/os-release}"
    OS_NAME="Linux" OS_ID="" OS_LIKE=""
    if [[ -r "$OS_RELEASE" ]]; then
        OS_NAME="$(os_field PRETTY_NAME)"
        [[ -n "$OS_NAME" ]] || OS_NAME="Linux"
        OS_ID="$(os_field ID)" OS_LIKE="$(os_field ID_LIKE)"
    fi

    if command -v apt-get >/dev/null && command -v dpkg >/dev/null; then
        install_deb
    elif command -v pacman >/dev/null && [[ " $OS_ID $OS_LIKE " == *" arch "* ]]; then
        install_arch
    else
        die "Byakaron is packaged for Ubuntu, Debian and Arch Linux (apt or pacman). This is $OS_NAME."
    fi
}

# A field of /etc/os-release, without its quotes.
os_field() {
    sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$OS_RELEASE" | head -n 1
}

# fetch_package <file name> <destination> [<url>]: the file from the latest
# release, checked against that release's SHA256SUMS. A <url> (the
# BYAKARON_*_URL overrides) is downloaded as it is, unchecked.
fetch_package() {
    local name="$1" dest="$2" pinned="${3:-}"
    local assets="${BYAKARON_ASSETS_URL:-$ASSETS}"
    local api="${BYAKARON_API_URL:-https://api.github.com/repos/${REPO}/releases?per_page=20}"
    local url="${pinned:-${assets}/${name}}"
    local sums_url="${assets}/SHA256SUMS"

    # GitHub's latest/ skips prereleases, so while there are only prereleases
    # (27.0.0-dev.1, say) it has nothing: take the newest release with this file.
    if [[ -z "$pinned" ]] && ! curl -fsL -r 0-0 -o /dev/null "$url" 2>/dev/null; then
        local preview
        preview="$(curl -fsL "$api" 2>/dev/null \
            | grep -o "\"browser_download_url\": *\"[^\"]*/${name}\"" | head -n 1 \
            | sed 's/.*"\([^"]*\)"$/\1/' || true)"
        [[ -n "$preview" ]] || die "could not find ${name} on ${REPO} (no release has it yet)"
        echo ">>> no stable release yet: installing the newest preview build"
        url="$preview"
        sums_url="${preview%/*}/SHA256SUMS"
    fi

    echo ">>> downloading $url"
    curl -fL --progress-bar -o "$dest" "$url" \
        || die "could not download $url (publish ${name} on ${REPO}, or set BYAKARON_DEB_URL / BYAKARON_PKG_URL)"

    # Same release's SHA256SUMS: a cut-off or damaged download stops here.
    [[ -z "$pinned" ]] || return 0
    if curl -fsL -o "$dest.sums" "$sums_url" 2>/dev/null; then
        local want got
        want="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$dest.sums")"
        got="$(sha256sum "$dest" | cut -d ' ' -f 1)"
        [[ -n "$want" && "$want" == "$got" ]] \
            || die "the download does not match SHA256SUMS ($name). Run the command again."
        echo ">>> checksum OK"
    else
        echo ">>> no SHA256SUMS next to the package, so the download is not checked"
    fi
}

# What changed, or the steps to add the input source on a first install.
# $3 says how to make IBus start on a desktop that is not GNOME.
report() {
    local was="$1" now="$2" start_ibus="$3"
    if [[ -n "$was" && "$was" == "$now" ]]; then
        echo; echo "=== Byakaron $now is already the latest ==="; echo
        return 0
    elif [[ -n "$was" ]]; then
        echo; echo "=== Byakaron updated: $was -> $now ==="
        echo "  Your input source stays as it is. Switch with Super+Space."; echo
        return 0
    fi

    echo
    echo "=== Byakaron $now is installed. Add it as an input source: ==="
    if command -v gnome-control-center >/dev/null; then
        echo "  1. Settings → Keyboard → Input Sources → '+'"
        echo "  2. Bangla → Byakaron (Bangla Phonetic) → Add"
        echo "  3. Switch with Super+Space and type ami then Space (আমি )"
        echo "  Or open the Byakaron app → Setup."
        echo "  If it is missing from the Bangla list, log out and back in."
        command -v gnome-shell >/dev/null \
            && echo "  Log out and back in once anyway to get Byakaron's suggestion panel."
    else
        echo "  1. $start_ibus"
        echo "  2. ibus-setup → Input Method → Add → Bangla → Byakaron"
        echo "  3. Switch with Super+Space and type ami then Space (আমি )"
        echo "  Or open the Byakaron app → Setup."
    fi
    echo
}

install_deb() {
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

    deb_name="byakaron_${ARCH}.deb"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    deb="$tmp/byakaron.deb"
    fetch_package "$deb_name" "$deb" "${BYAKARON_DEB_URL:-}"

    echo ">>> installing (keyboard + app + spell-check)"
    export DEBIAN_FRONTEND=noninteractive
    was_installed="$(dpkg-query -W -f='${Version}' byakaron 2>/dev/null || true)"
    if [[ "${EUID}" -eq 0 ]]; then
        BYAKARON_INSTALLER=1 apt-get install -y "$deb"
    else
        need sudo
        sudo env BYAKARON_INSTALLER=1 apt-get install -y "$deb"
    fi

    now_installed="$(dpkg-query -W -f='${Version}' byakaron 2>/dev/null || true)"
    # Shown without the epoch: the .deb is 1:0.1.x so it is newer than the
    # old Linux-only 0.2.x; people know the version as 0.1.x.
    was_shown="${was_installed#*:}" now_shown="${now_installed#*:}"
    # A prerelease is 27.0.0~dev.1 in dpkg; people know it as 27.0.0-dev.1.
    was_shown="${was_shown//\~/-}" now_shown="${now_shown//\~/-}"
    report "$was_shown" "$now_shown" \
        "Make IBus start with your desktop (as yourself, not root): im-config -n ibus, then log out and back in"
}

# pacman's 27.0.0dev.1-1 as people know it: 27.0.0-dev.1.
arch_shown() {
    local v="${1%-*}"
    [[ "$v" =~ ^([0-9.]+)([A-Za-z].*)$ ]] && v="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
    printf '%s' "$v"
}

install_arch() {
    local cpu
    cpu="$(uname -m)"
    case "$cpu" in
        x86_64) CPU_NAME="Intel/AMD 64-bit (x86_64)" ;;
        aarch64) die "this is Arch Linux ARM ($OS_NAME). Byakaron's Arch package is for Intel/AMD 64-bit (x86_64) so far." ;;
        *) die "unsupported CPU '$cpu' ($OS_NAME). Byakaron's Arch package is for Intel/AMD 64-bit (x86_64)." ;;
    esac
    echo ">>> Detected: $OS_NAME, $CPU_NAME"

    local name="byakaron_${cpu}.pkg.tar.zst"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    local pkg="$tmp/$name"
    fetch_package "$name" "$pkg" "${BYAKARON_PKG_URL:-}"

    echo ">>> installing (keyboard + app + spell-check)"
    was_installed="$(pacman -Q byakaron 2>/dev/null | cut -d ' ' -f 2 || true)"
    # pacman -U also installs ibus and GTK when they are missing, from the
    # system's package lists. Arch does not support partial upgrades, so this
    # never runs pacman -Sy; an out-of-date system says so and stops.
    local ok=1
    if [[ "${EUID}" -eq 0 ]]; then
        BYAKARON_INSTALLER=1 pacman -U --noconfirm "$pkg" || ok=0
    else
        need sudo
        sudo env BYAKARON_INSTALLER=1 pacman -U --noconfirm "$pkg" || ok=0
    fi
    [[ $ok -eq 1 ]] || die "pacman could not install Byakaron. If it could not download ibus or gtk3,
       bring the system up to date first (sudo pacman -Syu), then run this command again."

    now_installed="$(pacman -Q byakaron 2>/dev/null | cut -d ' ' -f 2 || true)"
    report "$(arch_shown "$was_installed")" "$(arch_shown "$now_installed")" \
        "Make IBus start with your desktop. KDE Plasma (Wayland): System Settings → Keyboard → Virtual Keyboard → IBus Wayland. Elsewhere: ibus-daemon -drxR at login (wiki.archlinux.org/title/IBus)"
}

command -v curl >/dev/null \
    || die "need curl: sudo apt install curl (Ubuntu, Debian) or sudo pacman -S curl (Arch)"
install_linux
