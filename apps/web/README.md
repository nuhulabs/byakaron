# Byakaron Web

Spell-check playground built with [Ziex](https://ziex.dev). It is part of the root build (`build.zig` → `ziex.init` with `apps/web/app`), so it shares the repo's Zig cache.

```sh
zig build db        # once: builds zig-out/db/spell.db
zig build run-web   # dev server with hot reload
zig build serve-web # production-mode server
```

Spell check and SQLite autocomplete read the app database `zx.db`. Natively that is `<install prefix>/db/spell.db`, opened read-only at startup (`app/pages/spell.zig`). On Cloudflare it is the D1 database bound as `DB`. The in-memory autocomplete uses the Avro lexicon embedded in `autocomplete_mem`.

## Cloudflare

The site deploys as the Worker `byakaron` (`wrangler.jsonc`, entry `main.ts`). Its build command runs `zig build -Dtarget=wasm32-wasi --release=small`, which builds the server to `zig-out/bin/web.wasm`, the Cloudflare bindings to `zig-out/bindings/` and the assets to `zig-out/static/`. The `web` job in `.github/workflows/cd.yml` deploys on every push to `main` (or by hand).

### Spell database

`zig build d1` writes spell.db as D1 migrations to `zig-out/d1/` (`migrations_dir` in `wrangler.jsonc`), and `wrangler d1 migrations apply DB` loads them like any other migrations:

- `0000_…` drops and recreates every table, the data files insert the rows (statements under D1's 100 KB limit, files of at most 4 MB), and the last file creates the indexes.
- Every file name carries a hash of the whole set, so a changed spell.db is a new set that wrangler applies from scratch; an unchanged one is already applied and nothing runs. Spell check is unavailable while a new set loads.
- Each data file first deletes the rows it inserts, so after a failure (network, timeout) rerunning `migrations apply` picks up where it stopped.

The database keeps the 150 000 most frequent words by default: about 460 MB, under D1's 500 MB Free-plan database limit. `-Ddb-words=N` (or `BYAKARON_DB_WORDS=N`) changes that, for `zig build db` too; `-Dspell-db=<path>` uses an existing spell.db instead of building one. Loading 150 000 words writes about 6.8 M rows (68 files, 260 MB of SQL), so it needs Workers Paid; the Free plan allows 100 000 rows written per day.

### Setup

1. Create the D1 database and the KV namespace, and put their ids into `wrangler.jsonc` (`d1_databases[0].database_id`, `kv_namespaces[0].id`):

   ```sh
   cd apps/web
   npx wrangler@4.100.0 d1 create byakaron
   npx wrangler@4.100.0 kv namespace create byakaron
   ```

2. In the GitHub repository, add the secrets `CLOUDFLARE_API_TOKEN` (permissions: Workers Scripts edit, D1 edit, Workers KV edit) and `CLOUDFLARE_ACCOUNT_ID`, available to the `byakaron-web` environment.

3. Deploy: push to `main` or run **CD** by hand. The `web` job takes spell.db from the job that builds it, runs `zig build d1`, applies the migrations to the remote database and deploys the Worker.

### Local

```sh
zig build db
zig build d1 -Ddb-words=20000   # a smaller set loads faster locally
cd apps/web
npx wrangler@4.100.0 d1 migrations apply DB --local
npx wrangler@4.100.0 dev
curl -X POST localhost:8787/api/spell -d '{"text":"আমি বাংলা"}'
```
