import { basename, extname, join } from "path";
import { existsSync } from "fs";
import { $ } from "bun";
import { ASSET_PATH, DATA_SOURCES } from "../constant";

async function handler() {
  try {
    const sources = DATA_SOURCES;
    console.log(`Found ${sources.length} sources to download`);

    // Run downloads in parallel using Promise.all
    await Promise.all(sources.map(downloadFile));

    console.log("All downloads completed!");
  } catch (error) {
    console.error("Error in handler:", error);
  }
}

handler();

async function downloadFile(source: { id: number; url: string; type: string }) {
  try {
    console.log(`Processing: ${source.url}`);

    const urlBasename = basename(source.url);
    const isGzipped = source.url.endsWith(".gz");
    const isBzipped = source.url.endsWith(".bz2");
    const isCompressed = isGzipped || isBzipped;
    const downloadFilename = join(ASSET_PATH, `${source.id}_${urlBasename}`);

    // Determine final filename with proper extension
    let baseFilename = isCompressed
      ? isGzipped
        ? urlBasename.replace(".gz", "")
        : urlBasename.replace(".bz2", "")
      : urlBasename;
    const existingExt = extname(baseFilename);
    const typeExt = getFileExtension(source.type);

    // Only add type extension if file doesn't already have an extension
    const finalBasename = existingExt
      ? baseFilename
      : `${baseFilename}${typeExt}`;
    const finalFilename = join(ASSET_PATH, `${source.id}_${finalBasename}`);

    // Check if final file already exists
    if (existsSync(finalFilename)) {
      console.log(`File already exists, skipping: ${finalFilename}`);
      return;
    }

    // Check if compressed file exists before downloading
    if (isCompressed && existsSync(downloadFilename)) {
      console.log(
        `Compressed file exists, skipping download: ${downloadFilename}`,
      );
    } else {
      // Download file using curl with progress
      console.log(`Starting download: ${source.url}`);
      const result =
        await $`curl -L --progress-bar ${source.url} -o ${downloadFilename}`;

      if (result.exitCode !== 0) {
        throw new Error(
          `Failed to download ${source.url}: curl exited with code ${result.exitCode}`,
        );
      }
    }

    // Handle compressed files
    if (isCompressed) {
      console.log(`Extracting compressed file: ${downloadFilename}`);

      if (isGzipped) {
        // Extract gzipped file to a new file without removing the original
        await $`gunzip -c ${downloadFilename} > ${finalFilename}`;
      } else if (isBzipped) {
        // Extract bz2 file to a new file without removing the original
        await $`bunzip2 -c ${downloadFilename} > ${finalFilename}`;
      }

      console.log(`Successfully extracted to: ${finalFilename}`);
    } else {
      // If not compressed and filenames are different, create a copy instead of moving
      if (downloadFilename !== finalFilename) {
        await $`cp ${downloadFilename} ${finalFilename}`;
      }
    }

    console.log(`Successfully processed: ${finalFilename}`);
  } catch (error) {
    console.error(`Error processing ${source.url}:`, error);
  }
}

function getFileExtension(type: string): string {
  switch (type) {
    case "mysql_dump":
    case "postgres_dump":
      return ".sql";
    case "csv":
      return ".csv";
    case "json":
      return ".json";
    case "yaml":
      return ".yaml";
    case "xml":
      return ".xml";
    case "html":
      return ".html";
    case "markdown":
      return ".md";
    case "text":
      return ".txt";
    default:
      return ".txt";
  }
}
