import { execSync } from "child_process";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";

const packages = ["stemming", "pos", "tokenization", "ner"];
const rootDir = process.cwd();
const distDir = join(rootDir, "dist", "packages");

packages.forEach((pkg) => {
  const pkgDir = join(rootDir, "packages", "core", pkg);
  const pkgDistDir = join(distDir);
  mkdirSync(pkgDistDir, { recursive: true });

  // Build the package
  execSync(`bun build ${pkgDir} --outdir ${pkgDistDir}`);

  // Update package.json
  const pkgJsonPath = join(pkgDir, "package.json");
  const pkgJson = JSON.parse(readFileSync(pkgJsonPath, "utf-8"));
  if (!pkgJson.main) return;
  if (pkgJson.private !== false) return;

  pkgJson.main = pkgJson.main.replace(".ts", ".js");
  pkgJson.module = pkgJson.module?.replace(".ts", ".js");

  // Write updated package.json to dist
  const distPkgJsonPath = join(pkgDistDir, "package.json");
  writeFileSync(distPkgJsonPath, JSON.stringify(pkgJson, null, 2));
});

console.log("Build complete.");
