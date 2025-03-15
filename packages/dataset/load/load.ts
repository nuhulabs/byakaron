import type { DataTypes } from "@bngc/db";
import { prisma } from "@bngc/db";
import { readdir } from "node:fs/promises";
import * as path from "path";
import { ASSET_PATH } from "../constant";
// Batch size for file writes
const BATCH_SIZE = 100000;


async function handler() {
  try {
    console.log("Starting dataset loading process...");
    
    const sources = await prisma.datasources.findMany();
    console.log(`Found ${sources.length} data sources to process`);
    
    if (sources.length === 0) {
      console.log("No data sources found. Exiting.");
      return;
    }
    
    const assetFiles = await readdir(ASSET_PATH, { recursive: true });
    console.log(`Found ${assetFiles.length} files in asset directory`);

    for (const source of sources) {
      await loadSentences(source);
    }
   
  } catch (error) {
    console.error("Fatal error in dataset loading process:", error);
    process.exit(1);
  }
}

// Start the handler function and catch any unhandled errors
handler().catch(error => {
  console.error("Unhandled error in handler:", error);
  process.exit(1);
});

async function loadSentences(source: DataTypes.datasources) {
  const jsonlFilePath = path.join(ASSET_PATH, `${source.id}_transformed.jsonl`);
  const stdFilePath = path.join(ASSET_PATH, `${source.id}_std.jsonl`);
  const stdTxtFilePath = path.join(ASSET_PATH, `${source.id}_std.txt`);

}

