# Byakaron for Linux

Type Bangla by how it sounds: `ami` becomes আমি, `bangla` becomes বাংলা. It
works in every app, and the Byakaron app checks the spelling of Bangla text.

It works offline. The only time it goes online is a daily check for a new
version, which you can turn off.

## Install

Open a terminal and run:

```sh
curl -fsSL https://byakaron.com/install.sh | bash
```

It asks for your password once, and finds out by itself which Linux it is on.
It works on Intel/AMD and on 64-bit ARM computers, on:

| Linux | Also the systems built on it |
| --- | --- |
| Ubuntu 20.04, 22.04, 24.04, 26.04 | Linux Mint, Pop!_OS, Zorin OS, elementary OS, Kubuntu, Xubuntu |
| Debian 12, 13 | Raspberry Pi OS (64-bit), Kali Linux, LMDE, MX Linux, ChromeOS's Linux |
| Arch Linux | Manjaro, EndeavourOS, CachyOS, Garuda |
| Fedora | Nobara; Silverblue, Kinoite, Bazzite and Bluefin (see below) |
| RHEL 9 and its rebuilds | Rocky Linux, AlmaLinux, CentOS Stream |
| openSUSE Tumbleweed and Leap | |

- **Arch:** bring the system up to date first (`sudo pacman -Syu`), so pacman
  can fetch IBus and GTK if they are missing.
- **Fedora Silverblue, Kinoite, Bazzite, Bluefin:** the system is read-only,
  so Byakaron is added to it with rpm-ostree. Restart the computer once after
  installing.
- **A Chromebook:** turn on Linux first (**Settings → About ChromeOS →
  Developers → Linux development environment**), then run the command in the
  **Terminal** app. Byakaron then types in Linux apps (the Byakaron app,
  LibreOffice, Linux Firefox), not in Chrome or Android apps, which only take
  ChromeOS's own keyboards.
- **Not yet:** NixOS, Alpine, SteamOS, openSUSE Aeon and MicroOS, Void and
  Gentoo. The command says so and changes nothing.

## Turn it on

**Ubuntu and other GNOME desktops**

1. Open **Settings → Keyboard → Input Sources** and press **+**.
2. Choose **Bangla**, then **Byakaron**, and press **Add**.
3. Press **Super+Space** to switch between English and Byakaron.
4. Log out and back in once. GNOME then shows Byakaron's suggestion list, in
   blue, in every app.

**elementary OS**

1. Open **System Settings → Keyboard → Input Method**, press **+** and choose
   **Bangla → Byakaron**.
2. Press **Super+Space** to switch.

**KDE, Xfce, Cinnamon, Raspberry Pi OS and others**

1. Make IBus start with your desktop, then log out and back in:
   - KDE Plasma on Wayland, on any Linux: **System Settings → Keyboard →
     Virtual Keyboard → IBus Wayland**.
   - Linux Mint: **Menu → Preferences → Input Method → IBus**.
   - Ubuntu, Debian, Kali, Raspberry Pi OS: in a terminal, `im-config -n ibus`.
   - Fedora: in a terminal, `imsettings-switch ibus`.
   - Elsewhere: start `ibus-daemon -drxR` when you log in (see the Arch wiki's
     [IBus page](https://wiki.archlinux.org/title/IBus)).
2. Run `ibus-setup`, open **Input Method**, press **Add**, and choose
   **Bangla → Byakaron**.
3. Press **Super+Space** to switch.

**A Chromebook**

1. Restart Linux: right-click **Terminal** in the shelf, choose **Shut down
   Linux**, then open Terminal again. The install command has set IBus to
   start with Linux.
2. In Terminal, run `ibus-setup`, open **Input Method**, press **Add**, and
   choose **Bangla → Byakaron**.
3. In a Linux app, press **Search+Space** to switch.

The Byakaron app's **Setup** page walks through the same steps.

## Typing

| You type | You get |
| --- | --- |
| `ami bhalo achi` | আমি ভালো আছি |
| `2024` | ২০২৪ |
| `3.14`, `10:30` | ৩.১৪, ১০:৩০ |
| `.` at the end of a sentence | । |

- While you type, a list of words appears. **Space** takes the highlighted
  word, **1–9** pick one, the **arrow keys** move through the list and **Esc**
  cancels the word.
- Byakaron remembers the word you picked and offers it first next time.
- For numbers in English digits (0–9), turn off **Preferences → Typing → Bangla digits**
  in the Byakaron app.

## The Byakaron app

Open **Byakaron** from your apps.

- **Spelling** is the main window: paste or type Bangla text and wrong words
  are marked, with corrections in the bar under the text. The buttons at the
  top are the same as on Mac and Windows: the issue list, Open and Save on the
  left; **Bangla typing**, **Fix All**, **Copy** and **Clear** on the right.
- **Bangla typing** is the round button with **ক** and **A**. Blue with a large
  ক: what you type here comes out in Bangla, whatever keyboard your computer
  is set to. Outlined with a large A: your computer's own keyboard types here.
  Click it or press **Ctrl+T** to switch; the two letters swap places.
- **Preferences** (the menu at the top right, or Ctrl+,) has the same tabs as
  on Mac and Windows:
  - **Setup**: whether the keyboard is added, with an **Add** button that puts
    it in your desktop's own input source switcher (the top bar on GNOME, the
    IBus icon in the system tray elsewhere), and typing tips.
  - **Typing**: auto-correction, spelling fixes, learning your choices, Bangla
    digits and New line on Enter.
  - **Suggestions**: the list's direction and how many words it shows per page.
  - **Dictionary**: your own words, which Byakaron then suggests and never
    marks as wrong. Add one by hand or remove any. **Dictionary** in
    the menu opens the same list.
  - **Layout**: which English letters make which Bangla letter.
  - **Updates**: automatic updates, the release channel and **Check Now**.
- **About Byakaron** (in the menu): the version and the website.

## Updates

The app checks once a day. When there is a new version, a bar at the top says
**Byakaron … is available**. Press **Update** and enter your password. The
keyboard restarts by itself, then press **Restart** for the app.

On Fedora Silverblue, Kinoite, Bazzite and Bluefin the new version is added to
the system for the next start: restart the computer to finish.

You can also run the install command again at any time, or press **Check Now**
in **Preferences → Updates**. To stop the daily check, turn off **Auto-update**
there.

## Uninstall

One command for every distribution:

```sh
curl -fsSL https://byakaron.com/install.sh | bash -s -- --uninstall
```

Your own words and choices stay in `~/.local/share/byakaron`. Add `--purge`
to remove them too (`bash -s -- --uninstall --purge`). Log out and back in to
clear Byakaron from the input sources.

For a clean reinstall, uninstall with `--purge`, then run the install command
again. The install command always installs the latest stable release, even
over a newer preview build.

## If something is wrong

| Problem | What to do |
| --- | --- |
| Byakaron is not in the Bangla list | Log out and back in, then add it again. |
| The suggestion list is orange or looks different | Log out and back in once. GNOME loads Byakaron's look at login. |
| Numbers come out as 0–9 | Byakaron app → **Settings** → turn on **Bangla digits**. |
| `.` between numbers types । | Update Byakaron: newer versions keep the point (৩.১৪). |
| Nothing types in Bangla | Press **Super+Space** until Byakaron is selected. |
| On Arch, the install stops because pacman cannot download ibus or gtk3 | Run `sudo pacman -Syu`, then the install command again. |
| On a Chromebook, nothing types in Bangla | Restart Linux (right-click Terminal → Shut down Linux), and start the app from the launcher, not from Terminal. |
| In Telegram, VLC or KDE apps on Ubuntu 20.04 or 22.04, a word disappears when you click | Byakaron app → **Settings** → turn on **Qt apps: type a word once on click**. |

More: https://byakaron.com
