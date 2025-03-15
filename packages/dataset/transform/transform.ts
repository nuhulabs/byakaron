import type { DataTypes } from "@bngc/db";
import { prisma } from "@bngc/db";
import { createReadStream, createWriteStream, existsSync } from "fs";
import { readdir, writeFile, mkdir } from "node:fs/promises";
import * as path from "path";
import { extname } from "path";
import { createInterface } from "readline";
import { ASSET_PATH } from "../constant";
import { cleanupSentences } from "./util";
import { wikiToStd } from "./wiki-jsonl-to-std";
import { transformWikiXmlToJsonl } from "./wiki-xml-to-jsonl";

// Batch size for file writes
const BATCH_SIZE = 100000;

async function handler() {
  try {
    const sources = await prisma.datasources.findMany();
    console.log(`Found ${sources.length} sources to download`);

    // Run downloads in parallel using Promise.all
    await Promise.all(sources.map(transformFile));
    
    console.log("All downloads completed!");
  } catch (error) {
    console.error("Error in handler:", error);
  }
};

handler();

async function transformFile(source: DataTypes.datasources) {
  try {
    console.log(`Processing: ${source.id} ${source.name}`);

    // Find files that start with the source ID in the assets directory
    const assetFiles = await readdir(ASSET_PATH);
    const sourceFile = assetFiles.find(file => file.startsWith(`${source.id}_`));
    
    if (!sourceFile) {
      console.error(`No file found for source ${source.id}`);
      return;
    }

    const sourceFilePath = path.join(ASSET_PATH, sourceFile);
    console.log(`Found file: ${sourceFilePath}`);

    // Determine if we need to transform the file to JSONL first
    const fileExt = extname(sourceFilePath).toLowerCase();
    let jsonlFilePath = sourceFilePath;
    
    // If the file is not already in JSONL format, transform it
    if (fileExt !== '.jsonl') {
      jsonlFilePath = path.join(ASSET_PATH, `${source.id}_transformed.jsonl`);
      
      // Check if transformed file already exists
      if (existsSync(jsonlFilePath)) {
        console.log(`Transformed file already exists, skipping transformation: ${jsonlFilePath}`);
      } else {
        // For wiki XML files, use the wiki transformer
        if (fileExt === '.xml' && source.type === 'xml') {
          console.log(`Transforming XML to JSONL: ${sourceFilePath} -> ${jsonlFilePath}`);
          await transformWikiXmlToJsonl({
            inputFile: sourceFilePath,
            outputFile: jsonlFilePath,
            verbose: true
          });
        } else {
          // For other file types, implement appropriate transformers
          // This is a placeholder for other file type transformations
          console.log(`Transformation for ${fileExt} files not implemented yet`);
          return;
        }
      }
    }

    // Define output file path for sentences
    const sentencesDir = path.join(ASSET_PATH, 'sentences');
    const sentencesFilePath = path.join(sentencesDir, `${source.id}_sentences.txt`);
    const stdFilePath = path.join(ASSET_PATH, `${source.id}_std.jsonl`);
    
    // Check if standard file already exists
    if (existsSync(stdFilePath)) {
      console.log(`Standard file already exists, skipping processing: ${stdFilePath}`);
      return;
    }

    // Ensure sentences directory exists
    if (!existsSync(sentencesDir)) {
      await mkdir(sentencesDir, { recursive: true });
    }

    // Now process the JSONL file to extract sentences and write to text file
    console.log(`Processing JSONL file: ${jsonlFilePath}`);
    
    // Create a read stream and readline interface for processing the JSONL file line by line
    const fileStream = createReadStream(jsonlFilePath);
    const rl = createInterface({
      input: fileStream,
      crlfDelay: Infinity
    });

    // Create write stream for sentences
    const writeStream = createWriteStream(sentencesFilePath);
    
    let sentencesBatch = new Set<string>();
    let processedLines = 0;
    
    // Process each line of the JSONL file
    for await (const line of rl) {
      try {
        // Parse the JSON line
        const jsonData = JSON.parse(line);
        
        // For wiki data, use the wiki to standard transformer
        let sentences: Set<string> | string[] = [];
        
        if (source.type === 'xml') {
          // Use wiki transformer for wiki data
          sentences = await wikiToStd(jsonData);
        } else {
          // For other types, use appropriate transformers or direct extraction
          // This is a placeholder for other data type processing
          if (typeof jsonData === 'string') {
            sentences = cleanupSentences(jsonData);
          } else if (jsonData.text) {
            sentences = cleanupSentences(jsonData.text);
          }
        }
        
        // Add unique sentences to the batch
        sentences.forEach(sentence => sentencesBatch.add(sentence));
        
        // When batch size is reached, write to file
        if (sentencesBatch.size >= BATCH_SIZE) {
          await writeSentencesBatch(Array.from(sentencesBatch), writeStream);
          processedLines += sentencesBatch.size;
          console.log(`Wrote ${processedLines} sentences so far...`);
          sentencesBatch = new Set<string>();
        }
      } catch (error) {
        console.error(`Error processing line: ${error}`);
        // Continue with the next line
      }
    }
    
    // Write any remaining sentences
    if (sentencesBatch.size > 0) {
      await writeSentencesBatch(Array.from(sentencesBatch), writeStream);
      processedLines += sentencesBatch.size;
    }
    
    // Close the write stream
    writeStream.end();
    
    // Mark processing as complete by creating an empty std file
    // This will allow us to skip processing in future runs
    await writeFile(stdFilePath, '');
    
    console.log(`Successfully processed: ${jsonlFilePath}, wrote ${processedLines} sentences to ${sentencesFilePath}`);
    console.log(`Created standard file marker: ${stdFilePath}`);
  } catch (error) {
    console.error(`Error processing ${source.url}:`, error);
  }
}

/**
 * Write a batch of sentences to a file
 */
async function writeSentencesBatch(sentences: string[], writeStream: NodeJS.WritableStream): Promise<void> {
  return new Promise((resolve, reject) => {
    // Write each sentence on a new line
    const data = sentences.join('\n') + '\n';
    
    // Write to stream
    const canContinue = writeStream.write(data, err => {
      if (err) {
        reject(err);
      }
    });
    
    if (canContinue) {
      resolve();
    } else {
      writeStream.once('drain', resolve);
    }
  });
}