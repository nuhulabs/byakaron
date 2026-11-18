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
module), so build that first:

```sh
zig build ios-libs
cd apps/ios/keyboard
bundle exec pod install
open GiellaKeyboard.xcworkspace   # run the HostingApp scheme
```

## App

`HostingApp/App/` is a SwiftUI app like the macOS one, in the iOS 26 style
(stock tab bar, navigation stacks and lists, which take Liquid Glass, plus
glass on the status card and buttons): Setup, Try (a Notes style page to type
with the keyboard), Layout (the Avro key map) and Settings (the shared
settings that apply on iOS, and the personal dictionary). It opens its own
composer on the keyboard's App Group data, so what it saves applies from the
keyboard's next word. It needs iOS 17; the keyboard extension runs on iOS 15.
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
screenshot of each keyboard and their keys' frames. `Support/e2e/run.py` runs
it on a matrix of simulators and checks each run with `Support/e2e/analyze.py`:

- the two keyboards line up: every key's drawn rectangle (found from the
  pixels) and the keyboard's top edge within 1px of the system's;
- the switch does not flicker: in a video of it, every frame is the system's
  keyboard, Byakaron's or a cross-fade of the two.

```sh
cd apps/ios/keyboard
Support/e2e/run.py --list                       # the matrix
Support/e2e/run.py                              # all of it
Support/e2e/run.py --devices 'iPhone 17$' --os 26.3 --appearance dark
```

The matrix is one iPhone per screen size (the newest, plain model where
there is one: iPhone 17 and 17 Pro Max, not also 17 Pro), iPhone 11 to 18,
on the latest release of each iOS from 26 (26.3, 27.x). `--all-phones` and an
exact release (`--os 26.0`) widen it. Phones of one screen size share a
layout, which `Keyboard/Models/PhoneLayouts` keeps one file per width with
its iOS differences.

The flicker check fails on Byakaron's own frames only. On iOS 26 the system
lays a keyboard out at the screen's height and shrinks it each time it
appears, with a dark grey behind the keys meanwhile (fixed in iOS 27;
[forum thread](https://developer.apple.com/forums/thread/813579),
[KeyboardKit#1041](https://github.com/KeyboardKit/KeyboardKit/issues/1041)).
Nothing a keyboard draws covers it, so frames where only that grey differs
are reported as the system's, not failed.

It makes a simulator per iPhone and iOS ("Byakaron E2E …") with English,
Byakaron and Emoji as its keyboards, and leaves the simulators you use alone.
Results (screenshots, `switch.mp4`, `flicker-*.png`, `report.json` and a
`summary.json`) go to `DerivedData/E2E/Results/<time>/`. Needs Python with
numpy and Pillow; the video is read with AVFoundation (`frames.swift`).

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
