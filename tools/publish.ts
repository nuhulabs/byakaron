import { $ } from "bun";
import { mkdirSync } from "fs";
import { readFile } from "fs/promises";
import { join } from "path";

import { packages } from "./constant";

const rootDir = process.cwd();
const distDir = join(rootDir, "dist", "packages");

async function main() {
  const startTime = Date.now();
  const builtPackages = [];

  for await (const pkg of packages) {
    const pkgDir = join(rootDir, "packages", "core", pkg);
    const pkgDistDir = join(distDir, "core", pkg);
    const pkgJsonPath = join(pkgDir, "package.json");
    const pkgJson = JSON.parse(await readFile(pkgJsonPath, "utf-8"));
    const pkgName = `${pkgJson.name}@${pkgJson.version}`;
    mkdirSync(pkgDistDir, { recursive: true });

    // Build the package
    console.log(`\x1b[33m📦 ${pkgName} - Publishing...\x1b[0m`);

    try {
      await $`cd ${pkgDistDir} && bun publish --access public`;
      console.log(`\x1b[32m✅ ${pkgName} - Done\x1b[0m\n`);
    } catch (error) {
      console.error(
        `\x1b[31m❌ ${pkgName} - Failed to publish: ${error}\x1b[0m`,
      );
    }

    builtPackages.push(pkgName);
  }

  const duration = ((Date.now() - startTime) / 1000).toFixed(2);
  console.log(
    `\x1b[32m✨ Build complete. ${builtPackages.length} packages built in ${duration}s.\x1b[0m`,
  );
}

main();
