#!/usr/bin/env bash
# Build libbyakaron.so (Zig core + JNI bridge) for every Android ABI and copy it into
# the keyboard app's jniLibs. Works on Linux and macOS hosts (bash 3.2+).
#
#   apps/android/scripts/build_zig.sh [jniLibs dir]
#
# The jniLibs dir is the first argument, else DEST_DIR, else
# apps/android/keyboard/app/src/main/jniLibs. Env: BUILD_MODE
# (ReleaseFast), MIN_API (21), ANDROID_NDK_ROOT / ANDROID_NDK_HOME / ANDROID_HOME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"  # repo root
DEST_DIR="${1:-${DEST_DIR:-"$ROOT_DIR/apps/android/keyboard/app/src/main/jniLibs"}}"
mkdir -p "$DEST_DIR"
DEST_DIR="$(cd "$DEST_DIR" && pwd)"  # absolute: the build runs from the repo root
BUILD_MODE="${BUILD_MODE:-ReleaseFast}"
MIN_API="${MIN_API:-21}"

case "$(uname -s)" in
    Darwin) HOST_TAG="darwin-x86_64" ;; # the NDK ships one universal darwin toolchain
    Linux) HOST_TAG="linux-x86_64" ;;
    *) echo "[-] Error: unsupported host $(uname -s)" >&2; exit 1 ;;
esac

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
        "${ANDROID_HOME:-}/ndk"
        "${ANDROID_SDK_ROOT:-}/ndk"
        "$HOME/Library/Android/sdk/ndk"
        "$HOME/Android/Sdk/ndk"
        "/opt/android-sdk/ndk"
        "/opt/android-ndk"
    )
    for base in "${candidate_dirs[@]}"; do
        if [[ -d "$base" ]]; then
            local latest
            # Newest version directory (sort -V is not in macOS' BSD sort; -t. -k numeric is).
            latest=$(find "$base" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
            if [[ -n "$latest" && -d "$base/$latest/toolchains/llvm/prebuilt" ]]; then
                echo "$base/$latest"
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

SYSROOT="$NDK_DIR/toolchains/llvm/prebuilt/$HOST_TAG/sysroot"
if [[ ! -d "$SYSROOT" ]]; then
    echo "[-] Error: Sysroot not found at: $SYSROOT" >&2
    exit 1
fi

# ABI:zig target (bash 3.2 has no associative arrays)
ABI_TARGETS=(
    "arm64-v8a:aarch64-linux-android"
    "armeabi-v7a:arm-linux-androideabi"
    "x86_64:x86_64-linux-android"
)

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$ROOT_DIR"

echo "==> Building Byakaron core engine for Android targets ($BUILD_MODE, min API $MIN_API)..."

for entry in "${ABI_TARGETS[@]}"; do
    ABI="${entry%%:*}"
    ZIG_TARGET="${entry#*:}"
    echo "--> Compiling for $ABI ($ZIG_TARGET)..."

    LIBC_CONF="$TMP_DIR/libc_${ABI}.txt"
    cat << EOF > "$LIBC_CONF"
include_dir=$SYSROOT/usr/include
sys_include_dir=$SYSROOT/usr/include/$ZIG_TARGET
crt_dir=$SYSROOT/usr/lib/$ZIG_TARGET/$MIN_API
msvc_lib_dir=
kernel32_lib_dir=
cc_dir=$SYSROOT/usr/lib/$ZIG_TARGET/$MIN_API
darwin_sdk_dir=
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
