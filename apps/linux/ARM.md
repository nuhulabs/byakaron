# Byakaron on ARM (Raspberry Pi / Ubuntu arm64)

Byakaron is published for **ARM 64-bit** as well as Intel/AMD. On a Raspberry
Pi the install is the same one command as everywhere else; the installer
detects the CPU and downloads the ARM package:

```bash
curl -fsSL https://nuhulabs.com/byakaron/install.sh | sudo bash
```

**Typing it by hand?** The character before `sudo` is a pipe `|`. Raspberry Pi
OS defaults to the UK keyboard layout, where the key that gives `|` on a US
keyboard types `~` instead; with `~` curl treats `sudo` and `bash` as web
addresses ("Could not resolve host: sudo") and only prints the script. Copy
and paste the command, or set your keyboard layout first
(Preferences → Raspberry Pi Configuration → Localisation → Keyboard).

## What you need

| Requirement | Why |
| --- | --- |
| Raspberry Pi 4 or 5 (or any ARM 64-bit computer) | The package is built for `arm64` |
| A **64-bit** system: Raspberry Pi OS (64-bit) or Ubuntu Desktop arm64 | There is no 32-bit (`armhf`) package; the installer says so and stops |
| A desktop session | The keyboard is an IBus input method |

Check what you have:

```bash
uname -m                    # aarch64 (a 64-bit processor)
dpkg --print-architecture   # arm64 (a 64-bit system); armhf means 32-bit
```

`aarch64` with `armhf` means a 64-bit Pi running the 32-bit Raspberry Pi OS:
install Raspberry Pi OS (64-bit) to use Byakaron.

Tested in CI on every push: the installer in clean Ubuntu 20.04, 22.04, 24.04
and Debian 12 (Raspberry Pi OS's base) containers on an ARM 64-bit runner,
then typing through the installed keyboard and opening the app.

## After installing

**Ubuntu (GNOME):** Settings → Keyboard → Input Sources → **+** → **Bangla** →
**Byakaron (Bangla Phonetic)** → Add, then Super+Space.

**Raspberry Pi OS, KDE, Xfce and other desktops** (no GNOME Settings):

1. Make IBus start with your desktop, as yourself (not root):
   `im-config -n ibus` (`sudo apt install im-config` if it is missing), then log out and back in.
2. Run `ibus-setup` → **Input Method** → **Add** → **Bangla** → **Byakaron**.
3. Switch with Super+Space, type `ami` then Space → আমি.

The Byakaron app's Setup page shows the steps for your desktop and opens the
right settings window.

Not yet checked on a real Raspberry Pi OS desktop session (the CI containers
have no desktop): if IBus does not appear after `im-config`, please report it.

## Building on the Pi yourself (optional)

Only needed to try unreleased changes. Building is heavy: use a Pi with 4 GB
RAM or more.

## 1. Source

```bash
sudo apt update
sudo apt install -y git curl

git clone git@github.com:nuhulabs/byakaron.git ~/Code/byakaron
# HTTPS: git clone https://github.com/nuhulabs/byakaron.git ~/Code/byakaron
```

Other dependencies (ziex, SQLite, the sysroot packages) are fetched by
`zig build` from `build.zig.zon`.

## 2. System packages

```bash
cd ~/Code/byakaron
sudo -E env "PATH=$PATH" zig build linux-deps   # needs Zig from step 3, so do that first
```

That installs IBus and the GTK3 input module. The build itself downloads the
headers and libraries it compiles against (a pinned Ubuntu sysroot).

## 3. Zig for aarch64

Use Zig **0.17.0** (pinned in `.tool-versions`), the **aarch64** tarball:

```bash
mkdir -p ~/.local/bin
V=0.17.0
curl -fSL -o /tmp/zig.tar.xz "https://ziglang.org/download/$V/zig-aarch64-linux-$V.tar.xz"
tar -C ~/.local -xf /tmp/zig.tar.xz
ln -sfn ~/.local/zig-aarch64-linux-$V/zig ~/.local/bin/zig

echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
zig version   # 0.17.0
```

## 4. Build and install

```bash
cd ~/Code/byakaron

# optional sanity check (ami → আমি)
zig build linux-smoke

zig build                       # as your user, so root does not own the cache
sudo -E zig build install-linux
```

`install-linux` builds for the host CPU (`aarch64`) against glibc 2.31 and
always as ReleaseFast. It installs the IBus engine system-wide
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

Typing does not need this. Spell-check in the GTK app does (`Byakaron.db` is
about 1 GB; `zig build db` downloads the bnwiki dump and builds it).

```bash
zig build db
sudo -E zig build install-linux -Dlinux-install-db
```

### Or package a Pi-native `.deb`

This builds one complete file (keyboard, GTK app, and `Byakaron.db`). If
`Byakaron.db` is not already generated, the step builds it first.

```bash
zig build package-linux
sudo apt install ./zig-out/pkg/byakaron_0.2.1_arm64.deb
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
sudo -E zig build uninstall-linux
```

removes everything `install-linux` added.

## What will not work

| Situation | Result |
| --- | --- |
| Install the `amd64.deb` on the Pi | Wrong CPU; apt/dpkg refuses it or the binary will not run |
| 32-bit Raspberry Pi OS (`armhf`) | No glibc 2.31 `-Dlinux-arch` target in `build.zig` |
| Ubuntu Server with no desktop | No IBus session to type into |
| 2 GB Pi with no extra swap | Zig likely runs out of memory |

Full Linux port notes (engine behaviour, Wayland, Fcitx5, CI) live in
[README.md](README.md).
