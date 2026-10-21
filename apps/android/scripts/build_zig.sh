#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"  # repo root
DEST_DIR="${DEST_DIR:-"$ROOT_DIR/../HeliBoard/app/src/main/jniLibs"}"
BUILD_MODE="${BUILD_MODE:-ReleaseFast}"
MIN_API="${MIN_API:-21}"

# Locate Android NDK
find_ndk() {
    if [[ -n "${ANDROID_NDK_ROOT:-}" && -d "$ANDROID_NDK_ROOT" ]]; then
        echo "$ANDROID_NDK_ROOT"
        return
    fi
    if [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then
        echo "$ANDROID_NDK_HOME"
        return
    fi
    local candidate_dirs=(
        "${ANDROID_HOME:-/home/$USER/Android/Sdk}/ndk"
        "/opt/android-sdk/ndk"
        "/opt/android-ndk"
    )
    for base in "${candidate_dirs[@]}"; do
        if [[ -d "$base" ]]; then
            local latest
            latest=$(find "$base" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n 1)
            if [[ -n "$latest" && -d "$latest/toolchains/llvm/prebuilt" ]]; then
                echo "$latest"
                return
            fi
        fi
    done
    echo ""
}

NDK_DIR=$(find_ndk)
if [[ -z "$NDK_DIR" ]]; then
    echo "[-] Error: Android NDK not found. Set ANDROID_NDK_ROOT or install NDK under Android SDK." >&2
    exit 1
fi

echo "[+] Using Android NDK at: $NDK_DIR"

SYSROOT="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
if [[ ! -d "$SYSROOT" ]]; then
    echo "[-] Error: Sysroot not found at: $SYSROOT" >&2
    exit 1
fi

declare -A ABI_TARGETS=(
    ["arm64-v8a"]="aarch64-linux-android"
    ["armeabi-v7a"]="arm-linux-androideabi"
    ["x86_64"]="x86_64-linux-android"
)

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$ROOT_DIR"

echo "==> Building Byakaron core engine for Android targets ($BUILD_MODE, min API $MIN_API)..."

for ABI in "${!ABI_TARGETS[@]}"; do
    ZIG_TARGET="${ABI_TARGETS[$ABI]}"
    echo "--> Compiling for $ABI ($ZIG_TARGET)..."

    LIBC_CONF="$TMP_DIR/libc_${ABI}.txt"
    cat << EOF > "$LIBC_CONF"
include_dir=$SYSROOT/usr/include
sys_include_dir=$SYSROOT/usr/include/$ZIG_TARGET
crt_dir=$SYSROOT/usr/lib/$ZIG_TARGET/$MIN_API
static_crt_dir=$SYSROOT/usr/lib/$ZIG_TARGET/$MIN_API
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=$SYSROOT/usr/lib/$ZIG_TARGET/$MIN_API
EOF

    zig build lib \
        --libc "$LIBC_CONF" \
        -Dtarget="$ZIG_TARGET" \
        -Doptimize="$BUILD_MODE"

    OUT_DIR="$DEST_DIR/$ABI"
    mkdir -p "$OUT_DIR"
    cp "$ROOT_DIR/zig-out/lib/libbyakaron.so" "$OUT_DIR/libbyakaron.so"
    echo "    ✓ Deployed: $OUT_DIR/libbyakaron.so ($(du -h "$OUT_DIR/libbyakaron.so" | cut -f1))"
done

echo "==> All Android ABIs built and deployed successfully to $DEST_DIR."
