# Byakaron for Android

The Android keyboard is a HeliBoard fork kept in its own (private) repository,
[`nuhulabs/byakaron-android`](https://github.com/nuhulabs/byakaron-android), and
pinned here as a git submodule at `apps/android/keyboard` (branch `dev`). This
directory also holds the monorepo-side tooling (`scripts/`).

All typing logic (Avro candidates, paging, learning, personal dictionary,
spelling corrections, settings) lives in the Zig core behind the JNI bridge in
`src/ffi/jni.zig` (class `com.byakaron.engine.ByakaronEngine`). The app only maps
key events to the composer and draws what it returns.

## Clone

```sh
git clone --recurse-submodules <this-repo-url>
# or, in an existing checkout:
git submodule update --init apps/android/keyboard
```

## Build the native library

Needs Zig and the Android NDK (found through `ANDROID_NDK_ROOT`,
`ANDROID_NDK_HOME`, `ANDROID_HOME/ndk/<newest>`, `~/Library/Android/sdk/ndk` or
`~/Android/Sdk/ndk`). Works on macOS and Linux:

```sh
apps/android/scripts/build_zig.sh
```

This builds `libbyakaron.so` for arm64-v8a, armeabi-v7a and x86_64 and copies it
to `apps/android/keyboard/app/src/main/jniLibs/<abi>/`. Override with `DEST_DIR`,
`BUILD_MODE` (default `ReleaseFast`) and `MIN_API` (default `21`).

Then build the app as usual from the submodule:

```sh
cd apps/android/keyboard
./gradlew assembleDebug
```

## Develop inside the submodule

The submodule is a normal clone of `byakaron-android`. Work, commit and push
there, then record the new commit here:

```sh
cd apps/android/keyboard
git switch dev            # submodules check out a detached HEAD by default
# ... edit, build, test ...
git commit -am "..." && git push

cd ../../..
git add apps/android/keyboard   # bump the gitlink to the pushed commit
git commit -m "chore(android): bump keyboard"
```

To pull the latest `dev` into the submodule: `git submodule update --remote apps/android/keyboard`.

Changes to the JNI surface touch both repos: change `src/ffi/jni.zig` here and
the `external fun`s in `app/src/main/java/com/byakaron/engine/ByakaronEngine.kt`
there, rebuild the `.so`, and land both.

## Pull HeliBoard upstream

`byakaron-android` is a fork of [HeliBoard](https://github.com/Helium314/HeliBoard)
but not a GitHub fork, so merge upstream by hand inside the submodule:

```sh
cd apps/android/keyboard
git remote add upstream https://github.com/Helium314/HeliBoard.git   # once
git fetch upstream && git merge upstream/main
```

Resolve conflicts, build, push to `byakaron-android`, then bump the gitlink here
as above.
