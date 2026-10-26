#!/usr/bin/env bash
# Rewrite apps/web/app/downloads.zon from a release dist/ (SHA256SUMS + files).
# Usage: scripts/update-downloads-zon.sh v0.1.0 dist
set -euo pipefail

TAG="${1:?usage: update-downloads-zon.sh <tag> <dist-dir>}"
DIST="${2:?usage: update-downloads-zon.sh <tag> <dist-dir>}"
VERSION="${TAG#v}"

[[ -d "$DIST" ]] || { echo "error: dist dir missing: $DIST" >&2; exit 1; }

python3 - "$VERSION" "$TAG" "$DIST" <<'PY'
import pathlib, sys, hashlib

version, tag, dist = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])

sums: dict[str, str] = {}
sums_path = dist / "SHA256SUMS"
if sums_path.exists():
    for line in sums_path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2:
            sums[parts[1]] = parts[0]

def sha256(path: pathlib.Path) -> str:
    if path.name in sums:
        return sums[path.name]
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

catalog = [
    ("macos", "macOS", "Apple Silicon & Intel · .dmg", "Byakaron.dmg"),
    ("windows", "Windows", "x64 installer · .exe", "Byakaron-Setup.exe"),
    ("linux_amd64", "Linux (amd64)", "Ubuntu / Debian · .deb", f"byakaron_{version}_amd64.deb"),
    ("linux_arm64", "Linux (arm64)", "Ubuntu / Debian · .deb", f"byakaron_{version}_arm64.deb"),
    ("android_apk", "Android (APK)", "Sideload · .apk", "Byakaron.apk"),
    ("android_aab", "Android (Play bundle)", "Play Store · .aab", "Byakaron.aab"),
]

out = [
    ".{",
    f'    .version = "{version}",',
    f'    .tag = "{tag}",',
    '    .repo = "nuhulabs/Byakaron-Assets",',
    "    .assets = .{",
]
for id_, label, detail, file in catalog:
    path = dist / file
    if not path.exists():
        continue
    digest = sha256(path)
    out += [
        "        .{",
        f'            .id = "{id_}",',
        f'            .label = "{label}",',
        f'            .detail = "{detail}",',
        f'            .file = "{file}",',
        f'            .sha256 = "{digest}",',
        "        },",
    ]
out += ["    },", "}"]
pathlib.Path("apps/web/app/downloads.zon").write_text("\n".join(out) + "\n")
print("wrote apps/web/app/downloads.zon")
PY
