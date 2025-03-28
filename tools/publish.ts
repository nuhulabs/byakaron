import { $ } from "bun";
import { mkdirSync } from "fs";
import { readFile } from "fs/promises";
import { join } from "path";

import { packages } from "./constant";

const rootDir = process.cwd();
const distDir = join(rootDir, "dist", "packages");

async function getPublishedVersion(packageName: string) {
  try {
    const result = await $`npm view ${packageName} version --json`.text();
    return result.trim();
  } catch (error) {
    // Package doesn't exist yet or other error
    return null;
  }
}

function compareVersions(v1: string, v2: string) {
  const v1Parts = v1.split(".").map(Number);
  const v2Parts = v2.split(".").map(Number);

  for (let i = 0; i < Math.max(v1Parts.length, v2Parts.length); i++) {
    const v1Part = v1Parts[i] || 0;
    const v2Part = v2Parts[i] || 0;

    if (v1Part > v2Part) return 1;
    if (v1Part < v2Part) return -1;
  }

  return 0;
}

async function main() {
  const startTime = Date.now();
  const builtPackages = [];

  for await (const pkg of packages) {
    const pkgDir = join(rootDir, "packages", "core", pkg);
    const pkgDistDir = join(distDir, "core", pkg);
    const pkgJsonPath = join(pkgDir, "package.json");
    const pkgJson = JSON.parse(await readFile(pkgJsonPath, "utf-8"));
    const pkgVersion = pkgJson.version;
    const pkgName = pkgJson.name;
    const pkgNameWithVersion = `${pkgName}@${pkgVersion}`;
    mkdirSync(pkgDistDir, { recursive: true });

    // Get the published version
    const publishedVersion = await getPublishedVersion(pkgName);

    console.log(
      `\x1b[33m📦 ${pkgNameWithVersion} - Checking versions...\x1b[0m`,
    );

    // Skip if the version is not greater than published
    if (
      publishedVersion &&
      compareVersions(pkgVersion, publishedVersion) <= 0
    ) {
      console.log(
        `\x1b[33m⏭️  ${pkgNameWithVersion} - Skipped (current: ${pkgVersion}, published: ${publishedVersion})\x1b[0m\n`,
      );
      continue;
    }

    // Build the package
    console.log(`\x1b[33m📦 ${pkgNameWithVersion} - Publishing...\x1b[0m`);

    try {
      await $`cd ${pkgDistDir} && bun publish --access public`;
      console.log(`\x1b[32m✅ ${pkgNameWithVersion} - Done\x1b[0m\n`);
      builtPackages.push(pkgNameWithVersion);
    } catch (error) {
      if (
        String(error).includes(
          "You cannot publish over the previously published versions",
        )
      ) {
        console.log(
          `\x1b[32m✅ ${pkgNameWithVersion} - Already published\x1b[0m\n`,
        );
      } else {
        console.error(
          `\x1b[31m❌ ${pkgNameWithVersion} - Failed to publish: ${error}\x1b[0m`,
        );
      }
    }
  }

  const duration = ((Date.now() - startTime) / 1000).toFixed(2);
  console.log(
    `\x1b[32m✨ Build complete. ${builtPackages.length} packages published in ${duration}s.\x1b[0m`,
  );
}

main();
