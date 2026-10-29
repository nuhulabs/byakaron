#!/usr/bin/env bash
# Byakaron — one-command install (Linux & macOS).
#
#   curl -fsSL https://<host>/install.sh | bash
#
# Downloads the latest installer from nuhulabs/Byakaron-Assets and installs it.
# Windows: use install.ps1 instead (irm …/install.ps1 | iex).
set -euo pipefail

REPO="${BYAKARON_REPO:-nuhulabs/Byakaron-Assets}"
ASSETS="https://github.com/${REPO}/releases/latest/download"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "need $1"; }

install_linux() {
    command -v apt-get >/dev/null && command -v dpkg >/dev/null \
        || die "Byakaron is packaged for Ubuntu and Debian (apt)."

    OS_RELEASE="${BYAKARON_OS_RELEASE:-/etc/os-release}"
    OS_NAME="Linux"
    if [[ -r "$OS_RELEASE" ]]; then
        OS_NAME="$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$OS_RELEASE" | head -n 1)"
        [[ -n "$OS_NAME" ]] || OS_NAME="Linux"
    fi

    ARCH="$(dpkg --print-architecture)"
    KERNEL_CPU="$(uname -m)"
    case "$ARCH" in
        amd64) CPU_NAME="Intel/AMD 64-bit (amd64)" ;;
        arm64) CPU_NAME="ARM 64-bit (arm64)" ;;
        armhf|armel)
            hint=""
            [[ "$KERNEL_CPU" == aarch64 ]] && hint=" The processor is 64-bit, but the installed system is 32-bit."
            die "this is a 32-bit ARM system ($ARCH).$hint
       Byakaron needs a 64-bit Ubuntu/Debian or Raspberry Pi OS (64-bit)." ;;
        i386) die "32-bit PC systems are not supported. Use 64-bit Ubuntu or Debian." ;;
        *) die "unsupported CPU '$ARCH'. Byakaron is built for amd64 and arm64." ;;
    esac
    echo ">>> Detected: $OS_NAME, $CPU_NAME"

    deb_name="byakaron_${ARCH}.deb"
    deb_url="${BYAKARON_DEB_URL:-${ASSETS}/${deb_name}}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    deb="$tmp/byakaron.deb"

    echo ">>> downloading $deb_url"
    curl -fL --progress-bar -o "$deb" "$deb_url" \
        || die "could not download $deb_url (publish ${deb_name} on ${REPO}, or set BYAKARON_DEB_URL)"

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
    if [[ -n "$was_installed" && "$was_installed" == "$now_installed" ]]; then
        echo; echo "=== Byakaron $now_shown is already the latest ==="; echo
        return 0
    elif [[ -n "$was_installed" ]]; then
        echo; echo "=== Byakaron updated: $was_shown -> $now_shown ==="
        echo "  Your input source stays as it is. Switch with Super+Space."; echo
        return 0
    fi

    echo
    echo "=== Byakaron $now_shown is installed. Add it as an input source: ==="
    if command -v gnome-control-center >/dev/null; then
        echo "  1. Settings → Keyboard → Input Sources → '+'"
        echo "  2. Bangla → Byakaron (Bangla Phonetic) → Add"
        echo "  3. Switch with Super+Space and type ami then Space (আমি )"
        echo "  Or open the Byakaron app → Setup."
    else
        echo "  1. im-config -n ibus   then log out and back in"
        echo "  2. ibus-setup → Input Method → Add → Bangla → Byakaron"
        echo "  3. Switch with Super+Space and type ami then Space (আমি )"
    fi
    echo
}

install_macos() {
    echo ">>> Detected: macOS ($(uname -m))"
    dmg_url="${BYAKARON_DMG_URL:-${ASSETS}/Byakaron.dmg}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    dmg="$tmp/Byakaron.dmg"

    echo ">>> downloading $dmg_url"
    curl -fL --progress-bar -o "$dmg" "$dmg_url" \
        || die "could not download $dmg_url (publish Byakaron.dmg on ${REPO}, or set BYAKARON_DMG_URL)"

    echo ">>> mounting disk image"
    attach_out="$(hdiutil attach -nobrowse -readonly "$dmg")"
    mnt="$(printf '%s\n' "$attach_out" | awk '/\/Volumes\//{print $NF; exit}')"
    [[ -n "$mnt" && -d "$mnt" ]] || die "could not mount $dmg"

    app=""
    for candidate in "$mnt"/Byakaron.app "$mnt"/*.app; do
        [[ -d "$candidate" ]] || continue
        app="$candidate"
        break
    done
    [[ -n "$app" ]] || { hdiutil detach "$mnt" -quiet || true; die "no .app found inside the disk image"; }

    dest="/Applications/$(basename "$app")"
    echo ">>> installing to $dest"
    rm -rf "$dest"
    if ! cp -R "$app" "$dest" 2>/dev/null; then
        need sudo
        sudo rm -rf "$dest"
        sudo cp -R "$app" "$dest"
        sudo chown -R "$(id -un):staff" "$dest" 2>/dev/null || true
    fi
    hdiutil detach "$mnt" -quiet || true
    xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

    echo
    echo "=== Byakaron is installed in Applications ==="
    echo "  Open it from Launchpad or Spotlight to finish keyboard setup."
    echo "  Or: open \"$dest\""
    echo
    open "$dest" 2>/dev/null || true
}

os="$(uname -s)"
case "$os" in
    Linux)
        need curl
        install_linux
        ;;
    Darwin)
        need curl
        install_macos
        ;;
    MINGW*|MSYS*|CYGWIN*)
        die "use PowerShell on Windows: irm https://<host>/install.ps1 | iex"
        ;;
    *)
        die "unsupported OS '$os' (Linux and macOS only; Windows uses install.ps1)"
        ;;
esac
