import { Ziex } from "../../zig-out/bindings/platforms/cloudflare";
import module from "../../zig-out/bin/web.wasm";

export default new Ziex<Env>({ module, kv: "KV", db: "DB" });
