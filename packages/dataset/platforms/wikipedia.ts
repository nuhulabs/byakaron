import * as fs from "fs";
import { createWriteStream } from "fs";
import * as path from "path";
import sax from "sax";
import { pipeline } from "stream/promises";

import { tokenizeToSentences } from "@bntk/tokenization";

import { Transfomer } from ".";
import type { DataSource, TransformOptions } from "../types";
import { displayProgressLegacy } from "../util";

export class WikipediaTransformer extends Transfomer {
  static readonly NAME = "wikipedia";
  name = WikipediaTransformer.NAME;

  extract(datasource: DataSource): Promise<boolean> {
    return Promise.resolve(true);
  }

  transform(datasource: DataSource): Promise<boolean> {
    return Promise.resolve(true);
  }

  static toJSONL = transformWikiXmlToJsonl;
  static toStd = wikiToStd;
}

// Helper function to convert wikitext to plain text
function wikiToStd(wikitext: WikiPage) {
  // const doc = wtf(wikitext.revision.text);
  // return doc.text();
  return tokenizeToSentences(mediawikitoplaintext(wikitext));
}

function mediawikitoplaintext(wikitext: WikiPage): string {
  const text = wikitext.revision.text;

  // Remove common MediaWiki syntax
  let plainText = text
    // Remove comments
    .replace(/<!--[\s\S]*?-->/g, "")

    // Remove templates/infoboxes {{...}}
    .replace(/\{\{[\s\S]*?\}\}/g, "")

    // Remove tables
    .replace(/\{\|[\s\S]*?\|\}/g, "")

    // Remove file/image links
    .replace(/\[\[(File|Image):[\s\S]*?\]\]/gi, "")

    // Remove category links
    .replace(/\[\[Category:[\s\S]*?\]\]/gi, "")

    // Handle internal links - keep the text but remove the link
    .replace(/\[\[([^|\]]*)\|([^\]]*)\]\]/g, "$2") // [[link|text]] -> text
    .replace(/\[\[([^\]]*)\]\]/g, "$1") // [[link]] -> link

    // Remove external links
    .replace(/\[https?:\/\/[^\s\]]*\s([^\]]*)\]/g, "$1") // [http://example.com text] -> text
    .replace(/\[https?:\/\/[^\s\]]*\]/g, "") // [http://example.com] -> ''

    // Remove formatting
    .replace(/'''([^']*)'''/g, "$1") // Bold
    .replace(/''([^']*)''/g, "$1") // Italic

    // Remove HTML tags
    .replace(/<[^>]*>/g, "")

    // Remove section headers
    .replace(/==+([^=]*)==+/g, "$1")

    // Remove list markers
    .replace(/^[*#:;]+\s*/gm, "")

    // Remove references
    .replace(/<ref[^>]*>[\s\S]*?<\/ref>/g, "")
    .replace(/<ref[^>]*\/>/g, "");

  // Clean up whitespace
  plainText = plainText
    .replace(/\n{3,}/g, "\n\n") // Replace multiple newlines with just two
    .replace(/^\s+|\s+$/g, ""); // Trim whitespace

  return plainText;
}

/**
 * Transforms a large Wiki XML dump to JSONL using SAX parser
 * This is a more efficient approach than loading the entire XML into memory
 */
async function transformWikiXmlToJsonl(
  options: TransformOptions,
): Promise<void> {
  const {
    inputFile,
    outputFile,
    maxPages = Infinity,
    batchSize = 1000,
    verbose = false,
  } = options;

  // Ensure output directory exists
  const outputDir = path.dirname(outputFile);
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  // Get file size for progress calculation
  const fileStats = fs.statSync(inputFile);
  const fileSize = fileStats.size;

  // Create output stream
  const outputStream = createWriteStream(outputFile);

  // No need to write opening bracket for JSONL format

  // Create SAX parser with position tracking
  const parser = sax.createStream(true, {
    trim: true,
    normalize: true,
    position: true, // Enable position tracking for progress
  });

  // Track state
  let currentPage: Partial<WikiPage> = {};
  let currentRevision: Partial<WikiPage["revision"]> = {};
  let currentContributor: Partial<WikiPage["revision"]["contributor"]> = {};
  let currentTag = "";
  let currentText = "";
  let isInPage = false;
  let isInRevision = false;
  let isInContributor = false;
  let pageCount = 0;
  let batchCount = 0;
  let startTime = Date.now();
  let lastTitle = "";

  // Create a custom position tracker using a transform stream
  let bytesProcessed = 0;

  // Set up a counter to track bytes processed
  const readStream = fs.createReadStream(inputFile);
  readStream.on("data", (chunk) => {
    bytesProcessed += chunk.length;
  });

  // Track position manually since position might not be available directly
  parser.on("opentag", (node) => {
    currentTag = node.name;

    if (currentTag === "page") {
      isInPage = true;
      currentPage = {};
      currentRevision = {};
    } else if (currentTag === "revision") {
      isInRevision = true;
      currentRevision = {};
    } else if (currentTag === "contributor") {
      isInContributor = true;
      currentContributor = {};
    }
  });

  // Handle text content
  parser.on("text", (text) => {
    currentText = text;

    if (isInPage) {
      if (isInRevision) {
        if (isInContributor) {
          if (currentTag === "username" && currentContributor)
            currentContributor.username = text;
          else if (currentTag === "id" && currentContributor)
            currentContributor.id = text;
          else if (currentTag === "ip" && currentContributor)
            currentContributor.ip = text;
        } else {
          if (currentTag === "id") currentRevision.id = text;
          else if (currentTag === "timestamp") currentRevision.timestamp = text;
          else if (currentTag === "text") currentRevision.text = text;
        }
      } else {
        if (currentTag === "title") {
          currentPage.title = text;
          lastTitle = text;
        } else if (currentTag === "id") currentPage.id = text;
        else if (currentTag === "ns") currentPage.ns = text;
      }
    }
  });

  // Handle closing tags
  parser.on("closetag", (tagName) => {
    if (tagName === "page") {
      isInPage = false;

      // Add the page to the output if it has content
      if (currentPage.title && currentPage.id && currentRevision.text) {
        const completePage: WikiPage = {
          title: currentPage.title!,
          id: currentPage.id!,
          ns: currentPage.ns || "0",
          revision: {
            id: currentRevision.id!,
            timestamp: currentRevision.timestamp!,
            text: currentRevision.text!,
          },
        };

        if (currentContributor && Object.keys(currentContributor).length > 0) {
          completePage.revision.contributor = currentContributor;
        }

        // Write the page to the output stream as a single JSONL line
        outputStream.write(JSON.stringify(completePage) + "\n");

        pageCount++;
        batchCount++;

        // Update progress
        if (verbose) {
          // Use our tracked bytes processed instead of parser.position
          displayProgressLegacy(
            fileSize,
            bytesProcessed,
            pageCount,
            maxPages,
            lastTitle,
            batchCount >= batchSize,
          );

          if (batchCount >= batchSize) {
            batchCount = 0;
          }
        }

        // Stop if we've reached the maximum number of pages
        if (pageCount >= maxPages) {
          parser.end();
        }
      }
    } else if (tagName === "revision") {
      isInRevision = false;
      currentPage.revision = currentRevision as WikiPage["revision"];
    } else if (tagName === "contributor") {
      isInContributor = false;
      if (currentContributor) {
        currentRevision.contributor = currentContributor;
      }
    }
  });

  // Handle errors
  parser.on("error", (err) => {
    console.error("Error parsing XML:", err);
    throw err;
  });

  // Handle end of input
  parser.on("end", () => {
    // No need to write closing bracket for JSONL format
    outputStream.end();

    if (verbose) {
      const elapsedSeconds = (Date.now() - startTime) / 1000;
      const pagesPerSecond = pageCount / Math.max(1, elapsedSeconds);
      console.log(
        `\nFinished processing ${pageCount} pages in ${elapsedSeconds.toFixed(
          2,
        )}s (${pagesPerSecond.toFixed(2)} pages/sec)`,
      );
      console.log(
        `Total file size processed: ${(bytesProcessed / (1024 * 1024)).toFixed(
          2,
        )}MB`,
      );
    }
  });

  // Start the pipeline
  try {
    await pipeline(readStream, parser);

    return Promise.resolve();
  } catch (error) {
    console.error("Pipeline error:", error);
    throw error;
  }
}

interface WikiPage {
  title: string;
  id: string;
  ns: string;
  revision: {
    id: string;
    timestamp: string;
    contributor?: {
      username?: string;
      id?: string;
      ip?: string;
    };
    text: string;
  };
}
