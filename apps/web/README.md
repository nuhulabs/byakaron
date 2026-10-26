# Byakaron Web

Spell-check playground built with [Ziex](https://ziex.dev). It is part of the root build (`build.zig` → `ziex.init` with `apps/web/app`), so it shares the repo's Zig cache.

```sh
zig build db        # once: builds zig-out/db/Byakaron.db
zig build run-web   # dev server with hot reload
zig build serve-web # production-mode server
```

Spell check and SQLite autocomplete read the app database `zx.db`. Natively that is `<install prefix>/db/Byakaron.db`, opened read-only at startup (`app/pages/spell.zig`). On Cloudflare it is the D1 database bound as `DB`. The in-memory autocomplete uses the Avro lexicon embedded in `autocomplete_mem`.

## Cloudflare

The site deploys as the Worker `byakaron` (`wrangler.jsonc`, entry `main.ts`), split in three:

- **The page is static.** `app/pages/page.zx` is `.rendering = .prerendered`: the build renders it once into `zig-out/static/index.html`, an empty shell whose UI is a `@client` component that runs in the browser (wasm). Everything that depends on the visitor (the saved draft and settings in the browser's storage, a shared `?q=` link) is read there. Cloudflare serves it, with the client wasm, the JS and the CSS, straight from its CDN; the Worker doesn't run for them.
- **Downloads** at `/download` list installers via stable `/releases/latest/download/…` URLs on public [`nuhulabs/Byakaron-Assets`](https://github.com/nuhulabs/Byakaron-Assets) (`app/downloads.zon`). No per-release web republish.
- **The API is dynamic.** `app/pages/api/spell/route.zig` is `.rendering = .request`: `POST /api/spell` runs in the Worker against the D1 database.

### Spell API and the browser cache

`/api/spell` takes words, not text, and checks each on its own (`Spell.checkWords`: suggestions are ranked without the neighbouring words' n-gram context), so the answer for a word is the same wherever it appears. Requests and responses are zxon (`zx.util.zxon`): valid JSON, sent as `application/json`, but positional arrays instead of objects, read and written without `std.json` in the page's code. The format is in `app/pages/api/spell/schema.zig`:

```sh
curl -X POST localhost:8787/api/spell -H 'content-type: application/json' --data-binary '[["আমি","ভালোবাশি"]]'
# [[["আমি",true,[]],["ভালোবাশি",false,[["ভালোবাসি",205,1,702000]]]]]
```

The page splits its text into words with the same tokenizer the server uses (`tokenization`, `.normalize = true`), answers every word it has cached and asks the API only for the others. The keyboard's corrections use the same cache. The cache is kept in memory and saved to `zx.kv` (the browser's IndexedDB) as one value under `spell_cache_v<N>`:

- **Version:** bump `SpellCache.version` in `page.zx` when the server's answers change (a new Byakaron.db, new ranking). Every browser then ignores and deletes its old cache.
- **Expiry:** each word expires 7 days after it was fetched (`SpellCache.ttl_ms`). The browser's kv has no TTL of its own, so the expiry is stored with each entry and checked when it is read.
- **Size:** at most 20 000 words (`SpellCache.max_entries`); the oldest go first.
- **Schema:** the value is written with `zx.kv.putAs`, so a change to the result types also invalidates it.

The build command is `zig build -Dtarget=wasm32-wasi --release=small -Dziex-config=.{.prerender=true}`. It builds the Worker to `zig-out/bin/web.wasm`, the Cloudflare bindings to `zig-out/bindings/` and the assets to `zig-out/static/`. Then, because of `prerender`, ziex builds the app for this machine, runs it without a database and saves the prerendered page into `zig-out/static/`. The `web` job in `.github/workflows/cd.yml` deploys on every push to `main` (or by hand).

Natively (`run-web`, `serve-web`) the server still renders the page itself.

### Spell database

`zig build d1` writes Byakaron.db as D1 migrations to `zig-out/d1/` (`migrations_dir` in `wrangler.jsonc`), and `wrangler d1 migrations apply DB` loads them like any other migrations:

- `0000_…` drops and recreates every table, the data files insert the rows (statements under D1's 100 KB limit, files of at most 4 MB), and the last file creates the indexes.
- Every file name carries a hash of the whole set, so a changed Byakaron.db is a new set that wrangler applies from scratch; an unchanged one is already applied and nothing runs. Spell check is unavailable while a new set loads.
- Each data file first deletes the rows it inserts, so after a failure (network, timeout) rerunning `migrations apply` picks up where it stopped.

The database keeps the 150 000 most frequent words by default: about 460 MB, under D1's 500 MB Free-plan database limit. `-Ddb-words=N` (or `BYAKARON_DB_WORDS=N`) changes that, for `zig build db` too; `-Dspell-db=<path>` uses an existing Byakaron.db instead of building one. Loading 150 000 words writes about 6.8 M rows (68 files, 260 MB of SQL), so it needs Workers Paid; the Free plan allows 100 000 rows written per day.

### Setup

1. Create the D1 database and the KV namespace, and put their ids into `wrangler.jsonc` (`d1_databases[0].database_id`, `kv_namespaces[0].id`):

   ```sh
   cd apps/web
   npx wrangler@4.100.0 d1 create byakaron
   npx wrangler@4.100.0 kv namespace create byakaron
   ```

2. In the GitHub repository, add the secrets `CLOUDFLARE_API_TOKEN` (permissions: Workers Scripts edit, D1 edit, Workers KV edit) and `CLOUDFLARE_ACCOUNT_ID`, available to the `byakaron-web` environment.

3. Deploy: push to `main` or run **CD** by hand. The `web` job takes Byakaron.db from the job that builds it, runs `zig build d1`, applies the migrations to the remote database and deploys the Worker.

### Deploy from your machine

Needs Zig 0.17, Node and a Cloudflare login (`npx wrangler@4.100.0 login`, or `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`).

```sh
# 1. Byakaron.db: build it locally (not published on Byakaron-Assets)
zig build db

# 2. Load it into D1; a no-op when this Byakaron.db is already there
zig build d1 -Dspell-db=zig-out/db/Byakaron.db
cd apps/web
npx wrangler@4.100.0 d1 migrations apply DB --remote

# 3. Build (Worker + prerendered page) and deploy
npx wrangler@4.100.0 deploy
```

`wrangler deploy` runs the build command itself. To look at the result before deploying:

```sh
cd ../.. && zig build -Dtarget=wasm32-wasi --release=small -Dziex-config=.{.prerender=true}
ls zig-out/static            # index.html, assets/, favicon.ico
cd apps/web && npx wrangler@4.100.0 deploy --dry-run --outdir .wrangler-artifact
```

### Local

The same Worker and static files, with a local D1:

```sh
zig build db
zig build d1 -Ddb-words=20000   # a smaller set loads faster locally
cd apps/web
npx wrangler@4.100.0 d1 migrations apply DB --local
npx wrangler@4.100.0 dev        # runs the build command, then http://localhost:8787
curl -X POST localhost:8787/api/spell -H 'content-type: application/json' --data-binary '[["আমি","বাংলা"]]'
```

`/` comes from `zig-out/static/index.html`, so after changing the page rebuild (`wrangler dev` rebuilds on changes under `app/`).
