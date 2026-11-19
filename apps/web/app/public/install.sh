#!/usr/bin/env bash
# Byakaron: one-command install (Linux & macOS).
#
#   curl -fsSL https://<host>/install.sh | bash
#   curl -fsSL https://<host>/install.sh | bash -s -- --uninstall
#   curl -fsSL https://<host>/install.sh | bash -s -- --uninstall --purge
#
# Downloads the latest installer from nuhulabs/Byakaron-Assets and installs it,
# replacing whatever Byakaron is installed, even a newer preview build.
# --uninstall removes it; --purge also deletes your settings, learned words
# and personal dictionary (~/.local/share/byakaron).
# Windows: use install.ps1 instead (irm …/install.ps1 | iex).
set -euo pipefail

REPO="${BYAKARON_REPO:-nuhulabs/Byakaron-Assets}"
ASSETS="https://github.com/${REPO}/releases/latest/download"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "need $1"; }

# One command for every Linux Byakaron is packaged for: the .deb with apt on
# Ubuntu, Debian and Raspberry Pi OS, the Arch package with pacman on Arch
# Linux and the systems built on it (Manjaro, EndeavourOS, …), and the .rpm
# with dnf on Fedora, RHEL and its rebuilds, or zypper on openSUSE.
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
    elif command -v rpm >/dev/null && { command -v dnf >/dev/null || command -v zypper >/dev/null; }; then
        install_rpm
    else
        die "Byakaron is packaged for Ubuntu, Debian, Arch Linux, Fedora, RHEL and openSUSE (apt, pacman, dnf or zypper). This is $OS_NAME."
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
        || die "could not download $url (publish ${name} on ${REPO}, or set BYAKARON_DEB_URL / BYAKARON_PKG_URL / BYAKARON_RPM_URL)"

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
    if [[ -z "$now" ]]; then
        die "Byakaron is not installed: the package manager stopped before installing it (see above)"
    elif [[ -n "$was" && "$was" == "$now" ]]; then
        echo; echo "=== Byakaron $now is already the latest ==="; echo
        return 0
    elif [[ -n "$was" ]]; then
        echo; echo "=== Byakaron $was is replaced by $now ==="
        echo "  Your input source stays as it is. Switch with Super+Space."; echo
        return 0
    fi

    echo
    echo "=== Byakaron $now is installed. Add it as an input source: ==="
    if command -v gnome-control-center >/dev/null; then
        echo "  1. Settings → Keyboard → Input Sources → '+'"
        echo "  2. Bangla → Byakaron → Add"
        echo "  3. Switch with Super+Space and type ami then Space (আমি )"
        echo "  Or open the Byakaron app → Preferences → Setup → Add."
        echo "  If it is missing from the Bangla list, log out and back in."
        command -v gnome-shell >/dev/null \
            && echo "  Log out and back in once anyway to get Byakaron's suggestion panel."
    else
        echo "  1. $start_ibus"
        echo "  2. ibus-setup → Input Method → Add → Bangla → Byakaron"
        echo "  3. Switch with Super+Space and type ami then Space (আমি )"
        echo "  Or open the Byakaron app → Preferences → Setup → Add."
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
       on a Raspberry Pi 4 or 5. See https://byakaron.com" ;;
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
    # --allow-downgrades: a preview build (27.1.0~beta.1, say) is newer than
    # the stable release this installs, and apt refuses to go back without it.
    local ok=1
    if [[ "${EUID}" -eq 0 ]]; then
        BYAKARON_INSTALLER=1 apt-get install -y --allow-downgrades "$deb" || ok=0
    else
        need sudo
        sudo env BYAKARON_INSTALLER=1 apt-get install -y --allow-downgrades "$deb" || ok=0
    fi
    [[ $ok -eq 1 ]] || die "apt-get could not install Byakaron (see above). Run: sudo apt-get update, then this command again."

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
        aarch64) CPU_NAME="ARM 64-bit (aarch64)" ;;
        *) die "unsupported CPU '$cpu' ($OS_NAME). Byakaron's Arch package is for x86_64 and aarch64." ;;
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

# rpm's 27.0.0~dev.1-1 as people know it: 27.0.0-dev.1.
rpm_shown() {
    local v="${1%-*}"
    printf '%s' "${v//\~/-}"
}

install_rpm() {
    local cpu
    cpu="$(uname -m)"
    case "$cpu" in
        x86_64) CPU_NAME="Intel/AMD 64-bit (x86_64)" ;;
        aarch64) CPU_NAME="ARM 64-bit (aarch64)" ;;
        *) die "unsupported CPU '$cpu' ($OS_NAME). Byakaron's RPM is for x86_64 and aarch64." ;;
    esac
    echo ">>> Detected: $OS_NAME, $CPU_NAME"

    local name="byakaron_${cpu}.rpm"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    local pkg="$tmp/$name"
    fetch_package "$name" "$pkg" "${BYAKARON_RPM_URL:-}"

    echo ">>> installing (keyboard + app + spell-check)"
    was_installed="$(rpm -q --qf '%{VERSION}-%{RELEASE}' byakaron 2>/dev/null || true)"
    [[ "$was_installed" == *" "* ]] && was_installed=""
    # dnf and zypper install ibus and GTK when they are missing. The package
    # is checked against SHA256SUMS above rather than signed.
    # A newer preview build installed: dnf install leaves it, dnf downgrade
    # replaces it; zypper goes back with --oldpackage.
    local cmd fallback=()
    if command -v dnf >/dev/null; then
        cmd=(dnf install -y "$pkg")
        fallback=(dnf downgrade -y "$pkg")
    else
        cmd=(zypper --non-interactive install --allow-unsigned-rpm --oldpackage "$pkg")
    fi
    local ok=1 sudo=()
    if [[ "${EUID}" -ne 0 ]]; then
        need sudo
        sudo=(sudo)
    fi
    ${sudo[@]+"${sudo[@]}"} env BYAKARON_INSTALLER=1 "${cmd[@]}" || ok=0
    local got
    got="$(rpm -q --qf '%{VERSION}-%{RELEASE}' byakaron 2>/dev/null || true)"
    if [[ ${#fallback[@]} -gt 0 && $ok -eq 1 && -n "$was_installed" && "$got" == "$was_installed" ]]; then
        ${sudo[@]+"${sudo[@]}"} env BYAKARON_INSTALLER=1 "${fallback[@]}" || ok=0
    fi
    [[ $ok -eq 1 ]] || die "${cmd[0]} could not install Byakaron. On RHEL, Rocky or AlmaLinux, enable EPEL first
       for ibus (sudo dnf install epel-release), then run this command again."

    now_installed="$(rpm -q --qf '%{VERSION}-%{RELEASE}' byakaron 2>/dev/null || true)"
    report "$(rpm_shown "$was_installed")" "$(rpm_shown "$now_installed")" \
        "Make IBus start with your desktop: imsettings-switch ibus (Fedora), or ibus-daemon -drxR at login, then log out and back in"
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

    # Mount at a path we pick: the volume name has spaces ("Byakaron 0.1.3"),
    # so reading it back out of the attach output is fragile. macOS 27
    # deprecates `hdiutil attach` in favour of `diskutil image attach`.
    echo ">>> mounting disk image"
    mnt="$tmp/mnt"
    if diskutil image attach --help >/dev/null 2>&1; then
        diskutil image attach --readOnly --nobrowse --mountPoint "$mnt" "$dmg" >/dev/null \
            || die "could not mount $dmg"
    else
        hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mnt" "$dmg" >/dev/null \
            || die "could not mount $dmg"
    fi
    trap 'hdiutil detach "$mnt" -quiet -force 2>/dev/null || true; rm -rf "$tmp"' RETURN

    app=""
    for candidate in "$mnt"/Byakaron.app "$mnt"/*.app; do
        [[ -d "$candidate" ]] || continue
        app="$candidate"
        break
    done
    [[ -n "$app" ]] || { hdiutil detach "$mnt" -quiet -force || true; die "no .app found inside the disk image"; }

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

# Remove Byakaron with the package manager that installed it; --purge also
# deletes the user's data. The input source goes with the package: log out and
# back in to clear it from the list.
uninstall_linux() {
    local sudo=()
    [[ "${EUID}" -eq 0 ]] || { need sudo; sudo=(sudo); }
    local removed=0
    if command -v dpkg-query >/dev/null && dpkg-query -W byakaron >/dev/null 2>&1; then
        local pkgs=(byakaron)
        for p in byakaron-app byakaron-data; do
            dpkg-query -W "$p" >/dev/null 2>&1 && pkgs+=("$p")
        done
        echo ">>> removing ${pkgs[*]}"
        ${sudo[@]+"${sudo[@]}"} env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}"
        removed=1
    elif command -v pacman >/dev/null && pacman -Q byakaron >/dev/null 2>&1; then
        echo ">>> removing byakaron"
        ${sudo[@]+"${sudo[@]}"} pacman -R --noconfirm byakaron
        removed=1
    elif command -v rpm >/dev/null && rpm -q byakaron >/dev/null 2>&1; then
        echo ">>> removing byakaron"
        if command -v dnf >/dev/null; then
            ${sudo[@]+"${sudo[@]}"} dnf remove -y byakaron
        else
            ${sudo[@]+"${sudo[@]}"} zypper --non-interactive remove byakaron
        fi
        removed=1
    fi
    [[ $removed -eq 1 ]] || echo ">>> Byakaron's package is not installed"

    local data="${XDG_DATA_HOME:-$HOME/.local/share}/byakaron"
    if [[ $PURGE -eq 1 ]]; then
        rm -rf "$data"
        echo ">>> removed your Byakaron data ($data)"
    elif [[ -d "$data" ]]; then
        echo ">>> kept your settings and words in $data (add --purge to remove them)"
    fi
    echo
    echo "=== Byakaron is uninstalled. Log out and back in to clear it from the input sources. ==="
    echo
}

uninstall_macos() {
    echo ">>> quitting Byakaron"
    killall Byakaron "Byakaron Keyboard" 2>/dev/null || true
    for app in "/Applications/Byakaron.app" "$HOME/Library/Input Methods/Byakaron Keyboard.app"; do
        [[ -e "$app" ]] || continue
        rm -rf "$app" 2>/dev/null || { need sudo; sudo rm -rf "$app"; }
        echo ">>> removed $app"
    done
    if [[ $PURGE -eq 1 ]]; then
        # The same list as `zig build remove -- macos` (src/build/macos.zig).
        rm -rf "$HOME/Library/Application Support/Byakaron" \
            "$HOME/Library/Preferences/dev.nuhu.labs.Byakaron.shared.plist" \
            "$HOME/Library/Preferences/dev.nuhu.labs.inputmethod.Byakaron.plist" \
            "$HOME/Library/Preferences/dev.nuhu.labs.Byakaron.plist" \
            "$HOME/Library/Saved Application State/dev.nuhu.labs.Byakaron.savedState" 2>/dev/null || true
        echo ">>> removed your Byakaron settings and words"
    fi
    echo
    echo "=== Byakaron is uninstalled. Remove it from System Settings → Keyboard → Input Sources if it is still listed. ==="
    echo
}

ACTION=install PURGE=0
for arg in "$@"; do
    case "$arg" in
        --uninstall|uninstall) ACTION=uninstall ;;
        --purge) PURGE=1 ;;
        -h|--help)
            echo "usage: install.sh [--uninstall [--purge]]"
            exit 0 ;;
        *) die "unknown option '$arg' (use --uninstall, optionally with --purge)" ;;
    esac
done

os="$(uname -s)"
if [[ "$ACTION" == uninstall ]]; then
    case "$os" in
        Linux) uninstall_linux ;;
        Darwin) uninstall_macos ;;
        *) die "unsupported OS '$os' for --uninstall (Linux and macOS only)" ;;
    esac
    exit 0
fi

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
