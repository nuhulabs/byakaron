/** Cloudflare Worker bindings (wrangler.jsonc). */
interface Env {
	KV: KVNamespace;
	DB: D1Database;
	/** Release installers — see `r2_buckets` in wrangler.jsonc. */
	RELEASES: R2Bucket;
	ASSETS: Fetcher;
}
