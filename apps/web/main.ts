import { Ziex } from "../../zig-out/bindings/platforms/cloudflare";
import module from "../../zig-out/bin/web.wasm";

const ziex = new Ziex<Env>({ module, kv: "KV", db: "DB" });

/** Content types for release installers served from R2. */
function contentType(file: string): string {
	if (file.endsWith(".dmg")) return "application/x-apple-diskimage";
	if (file.endsWith(".exe")) return "application/vnd.microsoft.portable-executable";
	if (file.endsWith(".deb")) return "application/vnd.debian.binary-package";
	if (file.endsWith(".apk")) return "application/vnd.android.package-archive";
	if (file.endsWith(".aab")) return "application/octet-stream";
	if (file.endsWith(".db")) return "application/x-sqlite3";
	return "application/octet-stream";
}

async function serveDownload(request: Request, env: Env): Promise<Response> {
	const url = new URL(request.url);
	const file = decodeURIComponent(url.pathname.replace(/^\/downloads\//, ""));
	if (!file || file.includes("..") || file.includes("/")) {
		return new Response("Not found", { status: 404 });
	}
	const object = await env.RELEASES.get(file);
	if (!object) {
		return new Response("Not found", { status: 404 });
	}
	const headers = new Headers();
	headers.set("content-type", contentType(file));
	headers.set("content-disposition", `attachment; filename="${file}"`);
	headers.set("cache-control", "public, max-age=3600, immutable");
	if (object.size != null) headers.set("content-length", String(object.size));
	if (object.etag) headers.set("etag", object.etag);
	return new Response(object.body, { headers });
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const path = new URL(request.url).pathname;
		if (path.startsWith("/downloads/")) {
			return serveDownload(request, env);
		}
		return ziex.fetch(request, env, ctx);
	},
};
