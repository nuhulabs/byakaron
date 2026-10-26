/** Cloudflare Worker bindings (wrangler.jsonc). */
interface Env {
	KV: KVNamespace;
	DB: D1Database;
	ASSETS: Fetcher;
}
