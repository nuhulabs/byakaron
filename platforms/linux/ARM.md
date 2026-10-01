# Byakaron on ARM (Raspberry Pi / Ubuntu arm64)

The published Linux `.deb` is **amd64** (64-bit Intel/AMD). It will not run on
a Raspberry Pi. The source is not AMD-only: build it **on the Pi** and
`install.sh` already targets ARM64 (`aarch64-linux-gnu.2.31`).

This is for **64-bit Ubuntu Desktop** on a Raspberry Pi 4 or 5. After install,
use it the same way as on an Intel Ubuntu box: add the input source, then
Super+Space.

## What you need

| Requirement | Why |
| --- | --- |
| Raspberry Pi 4 or 5, **4 GB RAM or more** | Zig compiles are heavy; 2 GB often runs out of memory |
| **64-bit** Ubuntu 22.04 or 24.04 Desktop (`arm64`) | Scripts support `x86_64` and `aarch64` only — not 32-bit `armhf` |
| A desktop session with IBus (Ubuntu Desktop / GNOME) | The engine is an IBus input method |

Confirm the CPU first:

```bash
uname -m                    # must print aarch64
dpkg --print-architecture   # must print arm64
```

If those say `armv7l` or `armhf`, this guide does not apply. Use a 64-bit
Ubuntu image.

Do **not** copy `byakaron_*_amd64.deb` onto the Pi.

If a GitHub Release with an `arm64` `.deb` exists, this is enough:

```bash
curl -fsSL https://nuhulabs.com/byakaron/install.sh | sudo bash
```

Otherwise build on the Pi as below.

## 1. Source and the `ziex` sibling

`build.zig.zon` expects `ziex` at `../../ziex-dev/ziex` relative to the
repository root (so if the repo is `~/Code/byakaron`, clone ziex to
`~/ziex-dev/ziex`).

```bash
sudo apt update
sudo apt install -y git curl

git clone git@github.com:nuhulabs/byakaron.git ~/Code/byakaron
# HTTPS: git clone https://github.com/nuhulabs/byakaron.git ~/Code/byakaron

git clone https://github.com/ziex-dev/ziex.git ~/ziex-dev/ziex
git -C ~/ziex-dev/ziex checkout 29f9a85b
```

Commit `29f9a85b` matters: the commit after it removes a build option this
project still passes.

## 2. System packages

```bash
cd ~/Code/byakaron
sudo bash platforms/linux/scripts/setup_deps.sh
```

That installs IBus, GTK3, and the C headers the engine and app need.

## 3. Zig for aarch64

This branch is pinned to **`0.17.0-dev.1422+e863bf3be`**. Newer Zig will not
compile. Use the **aarch64** tarball, not `zig-x86_64-linux-...`.

```bash
mkdir -p ~/.local/bin
V=0.17.0-dev.1422+e863bf3be
curl -fSL -o /tmp/zig.tar.xz \
  "https://pkg.hexops.org/zig/builds/zig-aarch64-linux-$V.tar.xz"
tar -C ~/.local -xf /tmp/zig.tar.xz
ln -sfn ~/.local/zig-aarch64-linux-$V/zig ~/.local/bin/zig

echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
zig version   # 0.17.0-dev.1422+e863bf3be
```

If that mirror 404s, fetch the same version's `zig-aarch64-linux-...tar.xz`
from another Zig community mirror and unpack it the same way.

## 4. Build and install

```bash
cd ~/Code/byakaron

# optional sanity check (ami → আমি)
bash platforms/linux/scripts/smoke.sh

sudo bash platforms/linux/scripts/install.sh
```

`install.sh` detects `aarch64` and builds with
`-Dtarget=aarch64-linux-gnu.2.31`. It installs the IBus engine system-wide
and, when GTK3 is present, the companion app.

First compile on a Pi can take a long time. If it dies on RAM, add swap and
retry:

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### Spell-check dictionary (optional)

Typing does not need this. Spell-check in the GTK app does (`spell.db` is
about 364 MB).

```bash
bash platforms/linux/scripts/prepare_spell_db.sh
sudo bash platforms/linux/scripts/install.sh
```

### Or package a Pi-native `.deb`

This builds one complete file (keyboard, GTK app, and `spell.db`). If
`spell.db` is not already generated, the script builds it first.

```bash
bash platforms/linux/scripts/package_deb.sh
sudo apt install ./platforms/linux/build/byakaron_0.1.7_arm64.deb
```

That file is `arm64`, not `amd64`. Use `apt`, not `dpkg -i`.

## 5. Use it

1. Settings → Keyboard → Input Sources → **+**
2. Choose **Bangla**, then **Byakaron (Bangla Phonetic)** → Add  
   The first dialog is a language list — searching “Byakaron” there finds nothing.
3. Switch with **Super+Space**
4. Type `ami` then Space — you should get `আমি `

The **Byakaron** app (Spelling / Layout / Setup) is optional. The keyboard
works without it. Launch the app and open Setup if you prefer that path over
GNOME Settings.

If Byakaron is missing from the Bangla list, log out and back in, then add
the input source again.

```bash
sudo bash platforms/linux/scripts/uninstall.sh
```

removes everything `install.sh` added.

## What will not work

| Situation | Result |
| --- | --- |
| Install the `amd64.deb` on the Pi | Wrong CPU; apt/dpkg refuses it or the binary will not run |
| 32-bit Raspberry Pi OS (`armhf`) | No glibc 2.31 Zig target in `scripts/compat.sh` |
| Ubuntu Server with no desktop | No IBus session to type into |
| 2 GB Pi with no extra swap | Zig likely runs out of memory |

Full Linux port notes (engine behaviour, Wayland, Fcitx5, CI) live in
[README.md](README.md).
