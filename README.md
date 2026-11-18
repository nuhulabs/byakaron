# Byakaron

A native Bangla keyboard for every major OS, built on one shared Zig engine
(transliteration, tokenization, spell check, autocomplete).

Requires Zig **0.17.0** (`minimum_zig_version` in `build.zig.zon`).

## Layout

| Path           | What                                                       |
| -------------- | ---------------------------------------------------------- |
| `src/`         | Zig engine + C FFI (`libbyakaron`, `src/ffi/byakaron.h`)   |
| `src/data/`    | Data pipeline: Wikipedia dump → `Byakaron.db`              |
| `src/build/`   | Build-time tools (generators, packaging, test drivers)     |
| `apps/web`     | Web app (ziex, part of the root build)                     |
| `apps/macos`   | macOS app + input method (Xcode)                           |
| `apps/ios`     | iOS keyboard (`byakaron-ios` submodule)                    |
| `apps/android` | Android keyboard (`byakaron-android` submodule)            |
| `apps/windows` | WinUI app + TSF input method                               |
| `apps/linux`   | IBus engine, GTK 3 app, optional Fcitx5                    |

## Build

Everything goes through `zig build`. Each platform is a step; the rest are
verbs that take a target after `--` (run a verb alone to list its targets).

```sh
zig build <platform>          # macos | ios | android | windows | web | linux → zig-out/bin
zig build pack -- <platform>  # release packages → zig-out/pkg
zig build dev -- <platform>   # install and start the app (web: the dev server)
zig build test                # unit tests
zig build e2e -- <suite>      # end-to-end tests: ios | linux | linux-wayland | linux-install
zig build gen -- <what>       # regenerate data: db | d1 | o-words | next-words | ios-settings | …
```

A few more: `zig build deps -- linux` installs the Linux packages,
`zig build remove -- macos|linux` uninstalls. Options go before `--` or after
it, as in `zig build pack -Dspell-db=zig-out/db/Byakaron.db -- macos`;
`zig build --help` lists them.

Each app's README has the details: [macOS](apps/macos), [iOS](apps/ios),
[Android](apps/android/README.md), [Windows](apps/windows/Keyboard/README.md),
[Linux](apps/linux/README.md), [web](apps/web/README.md).

## Data

Derived data is not committed: it comes out of the build graph and is cached
in `.zig-cache`.

- **Spell DB**: `zig build gen -- db` downloads the bnwiki dump and builds
  `zig-out/db/Byakaron.db` in cached stages, so a re-run only redoes what
  changed. The dump date lives in `src/data/db.zon` (`-Dwiki-date=YYYYMMDD`
  overrides it once, `-Dwiki-dump=<file>` uses a local dump). The release
  workflow caches `Byakaron.db` by that file alone: change the date, or bump
  its `revision` when the pipeline changes the data, to rebuild it in CI.
  SQLite, bzip2 and the XML parser are built from source.
- **Lexicon**: the autocomplete word list is committed as
  `src/AutoComplete/lexicon.zon` and compiled in; `zig build gen -- grammars
  -Diavro` resyncs it and the transliteration rules from their pinned source.
