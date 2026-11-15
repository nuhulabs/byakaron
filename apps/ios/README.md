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
