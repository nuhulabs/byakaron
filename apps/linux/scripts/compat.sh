# Sourced by package_deb.sh / install.sh / ci.sh.
# Ubuntu 20.04 is glibc 2.31. Zig can emit that ABI while still linking this
# machine's libibus and libglib, so one engine binary runs on 20.04, 22.04,
# and 24.04.

byk_compat_target_flag() {
    case "$(uname -m)" in
        x86_64) printf '%s' '-Dtarget=x86_64-linux-gnu.2.31' ;;
        aarch64|arm64) printf '%s' '-Dtarget=aarch64-linux-gnu.2.31' ;;
    esac
}

# Fail if $1 needs a GLIBC symbol newer than 2.31 (Ubuntu 20.04).
byk_assert_glibc_20_04() {
    local bin="$1"
    local ver
    command -v objdump >/dev/null || return 0
    ver="$(objdump -T "$bin" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -t. -k1,1n -k2,2n | uniq | tail -1)"
    [[ -n "$ver" ]] || return 0
    local maj="${ver%%.*}"
    local min="${ver#*.}"
    if [[ "$maj" -gt 2 ]] || { [[ "$maj" -eq 2 ]] && [[ "$min" -gt 31 ]]; }; then
        echo "error: $bin needs GLIBC_$ver — Ubuntu 20.04 only has 2.31" >&2
        echo "       rebuild with $(byk_compat_target_flag)" >&2
        return 1
    fi
    echo ">>> $bin highest GLIBC is $ver (Ubuntu 20.04-safe)"
}
