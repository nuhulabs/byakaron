import type { DataTypes } from "@bnkt/db";
import { prisma } from "@bnkt/db";
import { createReadStream, createWriteStream, existsSync } from "fs";
import { readdir, writeFile } from "node:fs/promises";
import * as path from "path";
import { extname } from "path";
import { createInterface } from "readline";
import { ASSET_PATH } from "../constant";
import { wikiToStd } from "../transform/wiki-jsonl-to-std";
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


    const stdFilePath = path.join(ASSET_PATH, `${source.id}_std.jsonl`);
    const stdTxtFilePath = path.join(ASSET_PATH, `${source.id}_std.txt`);
  
    // Check if standard file already exists
    if (existsSync(stdFilePath)) {
      console.log(
        `Standard file already exists, skipping processing: ${stdFilePath}`
      );
      return;
    }
  
    // Now process the JSONL file to extract sentences and insert directly to database
    console.log(`Processing JSONL file: ${jsonlFilePath}`);
  
    // Count total lines for progress tracking
    console.log("Counting total lines in JSONL file...");
    const totalLines = await countFileLines(jsonlFilePath);
    console.log(`Total lines in JSONL file: ${totalLines.toLocaleString()}`);
  
    // Create a read stream and readline interface for processing the JSONL file line by line
    const fileStream = createReadStream(jsonlFilePath);
    const rl = createInterface({
      input: fileStream,
      crlfDelay: Infinity,
    });
  
    // Create a write stream for the text file
    const txtWriteStream = createWriteStream(stdTxtFilePath, { flags: 'w' });
    
    // Write header to the text file
    txtWriteStream.write(`# Processed sentences from ${source.id}\n`);
    txtWriteStream.write(`# Generated on: ${new Date().toISOString()}\n\n`);
  
    let sentencesBatch = new Set<string>();
    let processedLines = 0;
    let startTime = Date.now();
    let totalSentencesProcessed = 0;
  
    try {
      // Process each line of the JSONL file
      for await (const line of rl) {
        try {
          // Parse the JSON line
          const jsonData = JSON.parse(line);
  
          // For wiki data, use the wiki to standard transformer
          let sentences = ['test', 'myu name is appon']
  
          // if (source.type === "xml") {
            // Use wiki transformer for wiki data
            sentences = Array.from(wikiToStd(jsonData));
          // } else {
          //   // For other types, use appropriate transformers or direct extraction
          //   // This is a placeholder for other data type processing
          //   if (typeof jsonData === "string") {
          //     sentences = cleanupSentences(jsonData);
          //   } else if (jsonData.text) {
          //     sentences = cleanupSentences(jsonData.text);
          //   }
          // }
  
          // Add unique sentences to the batch
          sentences.forEach((sentence) => sentencesBatch.add(sentence));
  
          // When batch size is reached, insert to database and write to text file
          if (sentencesBatch.size >= BATCH_SIZE) {
            // await insertSentencesBatch(Array.from(sentencesBatch), source.id);
            
            // Write sentences to text file
            await writeSentencesToTextFile(Array.from(sentencesBatch), txtWriteStream);
            
            totalSentencesProcessed += sentencesBatch.size;
            
            // Display progress
            displayJsonlProgress(totalLines, processedLines, sentencesBatch.size);
            
            // Clear the batch after successful insertion
            sentencesBatch = new Set<string>();
          }
  
          // Update progress after each line
          processedLines += 1;
          if (processedLines % 100 === 0) {
            displayJsonlProgress(totalLines, processedLines, sentencesBatch.size);
          }
        } catch (error) {
          console.error(`Error processing line: ${error}`);
          // Continue with the next line
        }
      }
  
      // Insert any remaining sentences
      if (sentencesBatch.size > 0) {
        // await insertSentencesBatch(Array.from(sentencesBatch), source.id);
        
        // Write remaining sentences to text file
        await writeSentencesToTextFile(Array.from(sentencesBatch), txtWriteStream);
        
        totalSentencesProcessed += sentencesBatch.size;
      }
  
      // Display final progress
      displayJsonlProgress(totalLines, processedLines, sentencesBatch.size, true);
  
      // Close the text file write stream
      txtWriteStream.end();
  
      // Mark processing as complete by creating an empty std file
      // This will allow us to skip processing in future runs
      await writeFile(stdFilePath, "");
  
      const elapsedSeconds = (Date.now() - startTime) / 1000;
      console.log(`\nSuccessfully processed: ${jsonlFilePath}`);
      console.log(
        `Processed ${processedLines.toLocaleString()} JSONL lines in ${elapsedSeconds.toFixed(
          2
        )}s`
      );
      console.log(`Total sentences inserted: ${totalSentencesProcessed.toLocaleString()}`);
      console.log(`Created standard file marker: ${stdFilePath}`);
      console.log(`Created text file with sentences: ${stdTxtFilePath}`);
    } catch (error) {
      console.error(`Error in loadSentences: ${error}`);
      // Don't create the std file marker if there was an error
      // This will allow the process to be retried next time
      
      // Close the text file write stream
      txtWriteStream.end();
    } finally {
      // Ensure the readline interface is closed
      rl.close();
      fileStream.close();
    }


  } catch (error) {
    console.error(`Error processing ${source.id}:`, error);
  }
}

/**
 * Display progress for JSONL processing
 */
const displayJsonlProgress = (() => {
  // Closure variables to track last update time and progress
  let lastUpdateTime = 0;
  let lastProcessedLines = 0;
  let startTime = Date.now();

  return function (
    totalLines: number,
    processedLines: number,
    currentBatchSize: number,
    force: boolean = false
  ) {
    const now = Date.now();
    const UPDATE_THRESHOLD_MS = 1000; // Update display every 1 second
    const UPDATE_THRESHOLD_LINES = 1000; // Or every 1000 lines

    // Only update if forced or thresholds are met
    if (
      !force &&
      now - lastUpdateTime < UPDATE_THRESHOLD_MS &&
      processedLines - lastProcessedLines < UPDATE_THRESHOLD_LINES
    ) {
      return;
    }

    // Update tracking variables
    lastUpdateTime = now;
    lastProcessedLines = processedLines;

    // Calculate progress percentage
    const progress =
      totalLines > 0
        ? Math.min(100, Math.round((processedLines / totalLines) * 100))
        : 0;

    // Create a progress bar
    const barLength = 30;
    const filledLength = Math.round((barLength * progress) / 100);
    const progressBar =
      "█".repeat(filledLength) + "░".repeat(barLength - filledLength);

    // Calculate elapsed time and processing rate
    const elapsedSeconds = (now - startTime) / 1000;
    const linesPerSecond = processedLines / Math.max(1, elapsedSeconds);

    // Calculate estimated time remaining
    const remainingLines = Math.max(0, totalLines - processedLines);
    const estimatedTimeRemaining =
      remainingLines / Math.max(0.1, linesPerSecond);

    // Format time
    const formatTime = (seconds: number): string => {
      if (!isFinite(seconds) || seconds <= 0) return "unknown";
      const hrs = Math.floor(seconds / 3600);
      const mins = Math.floor((seconds % 3600) / 60);
      const secs = Math.floor(seconds % 60);
      return `${hrs > 0 ? `${hrs}h ` : ""}${
        mins > 0 ? `${mins}m ` : ""
      }${secs}s`;
    };

    console.clear();
    console.log("JSONL Processing Progress");
    console.log(`[${progressBar}] ${progress}%`);
    console.log(
      `Lines: ${processedLines.toLocaleString()} / ${
        totalLines > 0 ? totalLines.toLocaleString() : "unknown"
      }`
    );
    console.log(`Current batch size: ${currentBatchSize.toLocaleString()}`);
    console.log(`Processing rate: ${linesPerSecond.toFixed(2)} lines/sec`);
    console.log(`Elapsed time: ${formatTime(elapsedSeconds)}`);
    console.log(
      `Estimated time remaining: ${formatTime(estimatedTimeRemaining)}`
    );
    console.log(`Last update: ${new Date().toLocaleTimeString()}`);
  };
})();

/**
 * Write a batch of sentences to a text file
 */
async function writeSentencesToTextFile(
  sentences: string[],
  writeStream: NodeJS.WritableStream
): Promise<void> {
  // Skip empty batches
  if (sentences.length === 0) {
    return;
  }

  return new Promise((resolve, reject) => {
    // Filter out empty or very short sentences
    const validSentences = sentences.filter(sentence => sentence && sentence.trim().length >= 3);
    
    // Skip if no valid sentences
    if (validSentences.length === 0) {
      resolve();
      return;
    }
    
    // Write each sentence on a new line
    for (const sentence of validSentences) {
      writeStream.write(`${sentence}\n`);
    }
    
    // Add a separator between batches for better readability
    writeStream.write(`\n`);
    
    resolve();
  });
}

/**
 * Count the number of lines in a file
 */
async function countFileLines(filePath: string): Promise<number> {
  return new Promise((resolve) => {
    let lineCount = 0;
    const rl = createInterface({
      input: createReadStream(filePath),
      crlfDelay: Infinity,
    });

    rl.on("line", () => lineCount++);
    rl.on("close", () => resolve(lineCount));
  });
}
