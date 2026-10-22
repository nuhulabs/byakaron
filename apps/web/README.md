# Byakaron Web

Spell-check playground built with [Ziex](https://ziex.dev). It is part of the root build (`build.zig` → `ziex.init` with `apps/web/app`), so it shares the repo's Zig cache.

```sh
zig build db        # once: builds zig-out/db/spell.db
zig build run-web   # dev server with hot reload
zig build serve-web # production-mode server
```

Spell check and SQLite autocomplete read the app database `zx.db`. Natively that is `<install prefix>/db/spell.db`, opened read-only at startup (`app/pages/spell.zig`); on Cloudflare it is the D1 database bound as `DB`. The in-memory autocomplete uses the Avro lexicon embedded in `autocomplete_mem`.

## Cloudflare

The site deploys as the Worker `byakaron` (`wrangler.jsonc`, entry `main.ts`): `zig build -Dtarget=wasm32-wasi --release=small` builds the server to `zig-out/bin/web.wasm`, the Cloudflare bindings to `zig-out/bindings/` and the assets to `zig-out/static/`. `.github/workflows/cd-web.yml` deploys on every push to `main` that touches `apps/web/`, `src/` or `build.zig*` (or by hand).

One-time setup:

1. Create the D1 database and the KV namespace, and put their ids into `wrangler.jsonc` (`d1_databases[0].database_id`, `kv_namespaces[0].id`):

   ```sh
   cd apps/web
   npx wrangler@4.100.0 d1 create byakaron
   npx wrangler@4.100.0 kv namespace create byakaron
   ```

   spell.db is about 1 GB, above the Workers Free plan's 500 MB D1 limit, so the account needs Workers Paid (10 GB per database). A full import writes ~14.4 M rows plus their index entries.

2. In the GitHub repository, add the secrets `CLOUDFLARE_API_TOKEN` (permissions: Workers Scripts edit, D1 edit, Workers KV edit) and `CLOUDFLARE_ACCOUNT_ID`, available to the `byakaron-web` environment.

3. Fill D1: run the **d1-import** workflow (Actions → d1-import → Run workflow). It downloads spell.db from the latest [Byakaron-Assets](https://github.com/nuhulabs/Byakaron-Assets/releases) release (or builds it with `zig build db`) and runs `scripts/d1_import.sh --remote`. Rerun it whenever spell.db changes; spell check is down while it runs.

4. Deploy: push to `main` or run **cd-web**.

### D1 import

`scripts/d1_import.sh` turns spell.db into SQL under `zig-out/d1/` and runs each file with `wrangler d1 execute DB --file`, in order:

- `0000-schema.sql`: `DROP TABLE IF EXISTS` + `CREATE TABLE`, so every full run starts from scratch
- `0001…-data.sql`: multi-row `INSERT`s, one statement per line (≤ 48 KB each, under D1's 100 KB limit), cut into files of at most 50 MB (`--chunk-mb`)
- the last file: `CREATE INDEX`, after the data

Today's spell.db (13.3 M `deletes`, 341 K `dictionary`, 637 K `bigrams`, 169 K `trigrams` rows) gives 12 files / 480 MB; the dump takes ~35 s. If a chunk fails, rerun with `--from N` to continue there.

```sh
zig build db
apps/web/scripts/d1_import.sh --dump-only          # just write zig-out/d1/
apps/web/scripts/d1_import.sh --local              # wrangler's local D1 (~4 min)
apps/web/scripts/d1_import.sh --remote             # the deployed database
apps/web/scripts/d1_import.sh --remote --from 7    # resume at chunk 7
```

To try the Worker locally against the local D1:

```sh
cd apps/web
npx wrangler@4.100.0 dev
curl -X POST localhost:8787/api/spell -d '{"text":"আমি বাংলা"}'
```
