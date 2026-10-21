# Byakaron Web

Spell-check playground built with [Ziex](https://ziex.dev). It is part of the root build (`build.zig` → `ziex.init` with `apps/web/app`), so it shares the repo's Zig cache.

```sh
zig build db        # once: builds zig-out/db/spell.db
zig build run-web   # dev server with hot reload
zig build serve-web # production-mode server
```

The app opens `<install prefix>/db/spell.db` read-only for spell check and SQLite autocomplete; the in-memory autocomplete uses the Avro lexicon embedded in `autocomplete_mem`.
