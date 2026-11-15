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

Needs Xcode and CocoaPods. See `apps/ios/keyboard/README.md`:

```sh
cd apps/ios/keyboard
pod install
open GiellaKeyboard.xcworkspace   # run the HostingApp scheme
```

## Status

The keyboard does not use the Byakaron engine yet. Building the engine for iOS
(`libbyakaron` as an xcframework, like `libbyakaron.a` for macOS) is blocked on
Zig 0.17's `std.Io.Threaded`, which does not compile for iOS: its process-spawn
code references a field the iOS `NullFile` does not have.

## Updating from upstream

```sh
cd apps/ios/keyboard
git remote add upstream https://github.com/divvun/giellakbd-ios.git   # once
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout dev && git rebase main && git push --force-with-lease origin dev
```
