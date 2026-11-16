# Byakaron for Linux

Type Bangla by how it sounds: `ami` becomes আমি, `bangla` becomes বাংলা. It
works in every app, and the Byakaron app checks the spelling of Bangla text.

It works offline. The only time it goes online is a daily check for a new
version, which you can turn off.

## Install

Open a terminal and run:

```sh
curl -fsSL https://nuhulabs.com/byakaron/install.sh | bash
```

It asks for your password once, and finds out by itself which Linux it is on.
It works on:

- Ubuntu 20.04, 22.04, 24.04 and 26.04, Debian 12 and 13, and Raspberry Pi OS
  (64-bit), on Intel/AMD and on 64-bit ARM computers
- Arch Linux, and the systems built on it such as Manjaro and EndeavourOS, on
  Intel/AMD computers

On Arch, bring the system up to date first (`sudo pacman -Syu`), so pacman
can fetch IBus and GTK if they are missing.

## Turn it on

**Ubuntu and other GNOME desktops**

1. Open **Settings → Keyboard → Input Sources** and press **+**.
2. Choose **Bangla**, then **Byakaron (Bangla Phonetic)**, and press **Add**.
3. Press **Super+Space** to switch between English and Byakaron.
4. Log out and back in once. GNOME then shows Byakaron's suggestion list, in
   blue, in every app.

**KDE, Xfce, Raspberry Pi OS and others**

1. Make IBus start with your desktop, then log out and back in:
   - Ubuntu, Debian, Raspberry Pi OS: in a terminal, `im-config -n ibus`.
   - Arch with KDE Plasma: **System Settings → Keyboard → Virtual Keyboard →
     IBus Wayland**.
   - Arch with another desktop: start `ibus-daemon -drxR` when you log in (see
     the Arch wiki's [IBus page](https://wiki.archlinux.org/title/IBus)).
2. Run `ibus-setup`, open **Input Method**, press **Add**, and choose
   **Bangla → Byakaron**.
3. Press **Super+Space** to switch.

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
- For numbers in English digits (0–9), turn off **Settings → Bangla digits**
  in the Byakaron app.

## The Byakaron app

Open **Byakaron** from your apps.

- **Spelling**: paste or type Bangla text and wrong words are marked, with
  corrections in the bar under the text. **Fix All** puts in the first
  correction for every marked word that has one.
  With the **Bangla typing** switch on, you can type Bangla here without
  changing your keyboard.
- **Layout**: which English letters make which Bangla letter.
- **Settings**: suggestions, spelling corrections, Bangla digits, the list's
  direction, and updates.
- **Personal Dictionary** (in the menu): your own words, which Byakaron then
  suggests and never marks as wrong.

## Updates

The app checks once a day. When there is a new version, a bar at the top says
**Byakaron … is available**. Press **Update** and enter your password. The
keyboard restarts by itself, then press **Restart** for the app.

You can also run the install command again at any time, or press **Check Now**
in **Settings → Updates**. To stop the daily check, turn off **Check for
updates** there.

## Uninstall

```sh
sudo apt remove byakaron       # Ubuntu, Debian, Raspberry Pi OS
sudo pacman -R byakaron        # Arch, Manjaro, EndeavourOS
```

Your own words and choices stay in `~/.local/share/byakaron`. Delete that
folder to remove them too.

## If something is wrong

| Problem | What to do |
| --- | --- |
| Byakaron is not in the Bangla list | Log out and back in, then add it again. |
| The suggestion list is orange or looks different | Log out and back in once. GNOME loads Byakaron's look at login. |
| Numbers come out as 0–9 | Byakaron app → **Settings** → turn on **Bangla digits**. |
| `.` between numbers types । | Update Byakaron: newer versions keep the point (৩.১৪). |
| Nothing types in Bangla | Press **Super+Space** until Byakaron is selected. |
| On Arch, the install stops because pacman cannot download ibus or gtk3 | Run `sudo pacman -Syu`, then the install command again. |
| In Telegram, VLC or KDE apps on Ubuntu 20.04 or 22.04, a word disappears when you click | Byakaron app → **Settings** → turn on **Qt apps: type a word once on click**. |

More: https://nuhulabs.com/byakaron
