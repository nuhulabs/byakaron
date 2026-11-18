# Byakaron for iOS

The iOS keyboard is a fork of [`divvun/giellakbd-ios`](https://github.com/divvun/giellakbd-ios)
kept in its own (private) repository,
[`nuhulabs/byakaron-ios`](https://github.com/nuhulabs/byakaron-ios), and pinned
here as a git submodule at `apps/ios/keyboard` (branch `dev`). Its `main` branch
tracks upstream; `dev` is Byakaron's work on top of it.

## Clone

```sh
git clone --recurse-submodules <this-repo-url>
# or, in an existing checkout:
git submodule update --init apps/ios/keyboard
```

## Build

Needs Zig, Xcode and CocoaPods (`bundle install` once; CocoaPods wants a UTF-8
locale). The keyboard links the engine from `zig-out/lib/ios/Byakaron.xcframework`
(device and simulator static libraries with `byakaron.h` as the `Byakaron`
module), which `zig build ios` builds along with the app:

```sh
(cd apps/ios/keyboard && bundle exec pod install)
zig build ios                     # → zig-out/bin/Byakaron-ios.app (simulator, unsigned)
zig build dev -- ios              # install and launch it on the booted simulator
open apps/ios/keyboard/GiellaKeyboard.xcworkspace   # or Xcode: the HostingApp scheme
```

## App

`HostingApp/App/` is a SwiftUI app like the macOS one, in the iOS 27 style
(stock tab bar, navigation stacks and lists, which take Liquid Glass, plus
glass on the status card and buttons): Setup, Try (a Notes style page to type
with the keyboard), Layout (the Avro key map) and Settings (the shared
settings that apply on iOS, and the personal dictionary). It opens its own
composer on the keyboard's App Group data, so what it saves applies from the
keyboard's next word. The app, the keyboard extension and the engine all need
iOS 27.
`-tab setup|try|layout|settings` at launch opens a tab.

## Engine

Typing goes through the Byakaron composer, as on every other platform:
`Keyboard/Controllers/BanglaComposer.swift` wraps the C ABI, the word being
typed is marked text and its candidates fill `CandidateBanner`. Settings and
learned choices are files in the App Group container.

The iOS engine has no SQLite, so no spelling corrections: candidates come from
the in-memory Avro lexicon. Zig 0.17's `std.Io.Threaded` (which SQLite and the
spell corrector need) does not compile for iOS, so `src/ffi/ffi.zig` leaves the
spell engine out there and the composer stores its files with libc
(`src/ffi/CFileStore.zig`).

## End-to-end tests

`KeyboardUITests` (its own scheme) switches from the system's English keyboard
to Byakaron in a text field with the globe key, as a person does, and keeps a
screenshot of each keyboard and their keys' frames. `zig build e2e -- ios`
(`src/build/ios_e2e.zig`) runs it on a matrix of simulators and checks each run:

- the two keyboards line up: every key's drawn rectangle (found from the
  pixels) and the keyboard's top edge within 1px of the system's;
- the switch does not flicker: in a video of it, every frame is the system's
  keyboard, Byakaron's or a cross-fade of the two.

```sh
zig build e2e -- ios --list                     # the matrix
zig build e2e -- ios                            # all of it
zig build e2e -- ios --devices "iPhone 17e" --os 27.0 --appearance dark
```

The matrix is one iPhone per screen size (the newest, plain model where
there is one: iPhone 17 and 17 Pro Max, not also 17 Pro), iPhone 11 to 18,
on the latest release of each iOS from 27, the oldest the keyboard runs on.
`--devices` takes comma-separated globs on the iPhone's name (default
`iPhone 1*,iPhone Air*`); `--all-phones` and an exact release (`--os 27.0`)
widen it. Phones of one screen size share a
layout, which `Keyboard/Models/PhoneLayouts` keeps one file per width with
its iOS differences.

CI runs the same matrix: `e2e.yml` (by hand, Actions → e2e → Run) builds once
and runs `KeyboardUITests` with the checks above on one job per iPhone and iOS,
from `zig build e2e -- ios --list --json` (its `ios-os` and `ios-devices`
inputs are `--os` and `--devices`; `--products` reuses the one build), keeping
each run's results as an artifact.

It makes a simulator per iPhone and iOS ("Byakaron E2E …") with English,
Byakaron and Emoji as its keyboards, and leaves the simulators you use alone.
Results (screenshots, `switch.mp4`, `flicker-*.png`, `report.json` and a
`summary.json`) go to `apps/ios/keyboard/DerivedData/E2E/Results/<time>/`.
`zig build e2e -- ios analyze <folder>` checks one result folder again.

The build is signed ad hoc (`CODE_SIGN_IDENTITY=-`), not with
`CODE_SIGNING_ALLOWED=NO`: without signing the App Group entitlement is gone
and the app stops at launch under test.

## Known issues

- The keyboard extension has not been tried on a device yet. The app launches
  in the simulator, but typing with the keyboard there needs it enabled in
  Settings, which has not been done.

## Updating from upstream

```sh
cd apps/ios/keyboard
git remote add upstream https://github.com/divvun/giellakbd-ios.git   # once
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout dev && git rebase main && git push --force-with-lease origin dev
```

## Release

`release.yml`'s `pack (ios)` archives the app for devices on every release.
With `IOS_CERTIFICATE` (+ `IOS_CERTIFICATE_PASSWORD`, an Apple Distribution
.p12, base64) and an App Store Connect API key (`APP_STORE_CONNECT_API_KEY`,
`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`) set, it signs and
exports `Byakaron.ipa` (profiles through Xcode's automatic signing with that
key) and `publish (ios)` uploads it to App Store Connect (TestFlight).
Without them the archive is unsigned and nothing is uploaded.
