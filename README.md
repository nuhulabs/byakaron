# Byakaron

A native, unified Bangla keyboard for all major OSes, built on a shared Zig engine (transliteration, tokenization, spell check, autocomplete).

Requires Zig **0.17.0** (pinned in `.tool-versions`).

## Layout

| Path               | What                                                              |
| ------------------ | ----------------------------------------------------------------- |
| `src/`             | Zig engine + C FFI (`libbyakaron`, `src/ffi/byakaron.h`)          |
| `src/data/`        | Data pipeline tools: Wikipedia dump → `spell.db`                  |
| `src/build/`       | Build-time tools (Avro lexicon generator, downloader)             |
| `apps/web`         | Web spell-check UI (ziex app, part of the root build)             |
| `apps/macos`       | macOS app + IME (Xcode)                                           |
| `apps/windows`     | WinUI app + TSF IME                                               |

## Data

Nothing derived is committed: every data file comes out of the Zig build graph and is cached in `.zig-cache`.

- **Autocomplete lexicon** (`AutoComplete/Mem.zig`, the default backend): `zig build` reads OmicronLab's Avro word database ([`iAvro/database.db3`](https://github.com/omicronlab/iAvro), hash-pinned in `build.zig.zon`) with `src/build/avro_dictionary.zig`, embeds the sorted word list, and installs `zig-out/db/{avro_dictionary.txt,Dictionary.json}` (the JSON is bundled by the macOS keyboard).
- **Spell DB**: `zig build db` downloads the bnwiki dump, then runs `sentences → triplets → export → prepare` (merging in the Avro lexicon) and installs `zig-out/db/spell.db`. Each stage is its own cached build step, so a re-run only redoes what changed. `zig build db-debug` builds the larger text-keyed `spell_debug.db`.

  ```sh
  zig build db                                  # bnwiki dump of -Dwiki-date (default 20261001)
  zig build db -Dwiki-date=20261101             # newer dump (dumps.wikimedia.org/bnwiki/)
  zig build db -Dwiki-dump=/path/to/bnwiki-latest-pages-articles.xml.bz2   # local file
  ```

  SQLite (CLI included), bzip2 and zig-xml are built from source, so no system tools are needed.

## Build

```sh
zig build            # libbyakaron + repl + web app + zig-out/db lexicon
zig build lib        # just libbyakaron + header + lexicon (used by platform scripts)
zig build test
zig build db         # spell.db (see Data)
zig build macos      # Byakaron.app via xcodebuild (stages spell.db + Dictionary.json)
zig build run-web    # apps/web dev server (builds spell.db first); serve-web for prod mode
zig build windows    # Byakaron-Setup.exe (on Windows)
```
