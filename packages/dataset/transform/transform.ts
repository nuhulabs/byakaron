import { prisma, type DataTypes } from "@bnkt/db";
import * as tokenization from "@bnkt/tokenization";
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
    await Promise.all(sources.map(processWordsFromSentences));
    
    console.log("All transformations completed!");
  } catch (error) {
    console.error("Error in handler:", error);
  }
}

handler();

async function transformFile(source: DataTypes.datasources) {
  try {
    console.log(`Processing: ${source.id} ${source.name}`);

    // Find files that start with the source ID in the assets directory
    const assetFiles = await readdir(ASSET_PATH);
    const sourceFile = assetFiles.find((file) =>
      file.startsWith(`${source.id}_`)
    );

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
    if (fileExt !== ".jsonl") {
      jsonlFilePath = path.join(ASSET_PATH, `${source.id}_transformed.jsonl`);

      // Check if transformed file already exists
      if (existsSync(jsonlFilePath)) {
        console.log(
          `Transformed file already exists, skipping transformation: ${jsonlFilePath}`
        );
      } else {
        // For wiki XML files, use the wiki transformer
        if (fileExt === ".xml" && source.type === "xml") {
          console.log(
            `Transforming XML to JSONL: ${sourceFilePath} -> ${jsonlFilePath}`
          );
          await transformWikiXmlToJsonl({
            inputFile: sourceFilePath,
            outputFile: jsonlFilePath,
            verbose: true,
          });
        } else {
          // For other file types, implement appropriate transformers
          // This is a placeholder for other file type transformations
          console.log(
            `Transformation for ${fileExt} files not implemented yet`
          );
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
    const txtWriteStream = createWriteStream(stdTxtFilePath, { flags: "w" });

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

          const sentences = Array.from(wikiToStd(jsonData));

          // Add unique sentences to the batch
          sentences.forEach((sentence) => sentencesBatch.add(sentence));

          // When batch size is reached, insert to database and write to text file
          if (sentencesBatch.size >= BATCH_SIZE) {
            // await insertSentencesBatch(Array.from(sentencesBatch), source.id);

            // Write sentences to text file
            await writeSentencesToTextFile(
              Array.from(sentencesBatch),
              txtWriteStream
            );

            totalSentencesProcessed += sentencesBatch.size;

            // Display progress
            displayJsonlProgress(
              totalLines,
              processedLines,
              sentencesBatch.size
            );

            // Clear the batch after successful insertion
            sentencesBatch = new Set<string>();
          }

          // Update progress after each line
          processedLines += 1;
          if (processedLines % 100 === 0) {
            displayJsonlProgress(
              totalLines,
              processedLines,
              sentencesBatch.size
            );
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
        await writeSentencesToTextFile(
          Array.from(sentencesBatch),
          txtWriteStream
        );

        totalSentencesProcessed += sentencesBatch.size;
      }

      // Display final progress
      displayJsonlProgress(
        totalLines,
        processedLines,
        sentencesBatch.size,
        true
      );

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
      console.log(
        `Total sentences inserted: ${totalSentencesProcessed.toLocaleString()}`
      );
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

    // After processing sentences, process words
    await processWordsFromSentences(source);
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
    const validSentences = sentences.filter(
      (sentence) => sentence && sentence.trim().length >= 3
    );

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

/**
 * Process sentences to extract words and create a words file
 */
async function processWordsFromSentences(source: DataTypes.datasources) {
  try {
    console.log(`\nProcessing words from sentences for source: ${source.id}`);

    // Define file paths
    const stdTxtFilePath = path.join(ASSET_PATH, `${source.id}_std.txt`);
    const wordsFilePath = path.join(ASSET_PATH, `${source.id}_words_std.txt`);
    const wordsJsonlFilePath = path.join(ASSET_PATH, `${source.id}_words_std.jsonl`);
    const wordGroupsJsonlFilePath = path.join(ASSET_PATH, `${source.id}_word_groups_std.jsonl`);

    // Check if words file already exists
    if (existsSync(wordsFilePath) && existsSync(wordsJsonlFilePath) && existsSync(wordGroupsJsonlFilePath)) {
      console.log(
        `Words files already exist, skipping processing: ${wordsFilePath}, ${wordsJsonlFilePath}, ${wordGroupsJsonlFilePath}`
      );
      return;
    }

    // Check if sentences file exists
    if (!existsSync(stdTxtFilePath)) {
      console.error(`Sentences file not found: ${stdTxtFilePath}`);
      return;
    }

    // Count total lines for progress tracking
    console.log("Counting total sentences in text file...");
    const totalLines = await countFileLines(stdTxtFilePath);
    console.log(`Total sentences in text file: ${totalLines.toLocaleString()}`);

    // Create read stream and readline interface
    const fileStream = createReadStream(stdTxtFilePath);
    const rl = createInterface({
      input: fileStream,
      crlfDelay: Infinity,
    });

    // Create write streams for the files
    const wordsWriteStream = createWriteStream(wordsFilePath, { flags: "w" });
    const wordsJsonlWriteStream = createWriteStream(wordsJsonlFilePath, { flags: "w" });
    const wordGroupsJsonlWriteStream = createWriteStream(wordGroupsJsonlFilePath, { flags: "w" });

    // Write headers to the words file
    wordsWriteStream.write(`# Processed words from ${source.id}\n`);
    wordsWriteStream.write(`# Generated on: ${new Date().toISOString()}\n\n`);

    let wordsBatch = new Set<string>();
    let wordsMap = new Map<string, { id: number, text: string, sentence_id: number | null, position: number | null }>();
    let wordGroupsMap = new Map<string, { prev_id: number, next_id: number, weight: number, occurance: number }>();
    let processedLines = 0;
    let startTime = Date.now();
    let totalWordsProcessed = 0;
    let totalWordGroupsProcessed = 0;
    let skippedLines = 0;
    let nextWordId = 1; // For generating word IDs in the JSONL file

    try {
      // Process each line of the sentences file
      for await (const line of rl) {
        try {
          // Skip empty lines, comments, or very short lines
          if (!line || line.trim().length < 3 || line.startsWith("#")) {
            skippedLines++;
            continue;
          }

          // Extract words from the sentence
          const words = tokenization.tokenizeToWords(line);
          const sentenceId = processedLines + 1; // Use line number as sentence ID for simplicity
          
          // Add words to batch and map
          words.forEach((word, position) => {
            wordsBatch.add(word);
            
            // Add word to words map if not already present
            if (!wordsMap.has(word)) {
              wordsMap.set(word, {
                id: nextWordId++,
                text: word,
                sentence_id: sentenceId,
                position: position + 1
              });
            }
          });
          
          // Create word groups (pairs of adjacent words)
          for (let i = 0; i < words.length - 1; i++) {
            const prevWord = words[i];
            const nextWord = words[i + 1];
            
            if (prevWord && nextWord) {
              const prevId = wordsMap.get(prevWord)?.id;
              const nextId = wordsMap.get(nextWord)?.id;
              
              if (prevId && nextId) {
                const key = `${prevId}-${nextId}`;
                
                // Check if we've already seen this pair
                const existingGroup = wordGroupsMap.get(key);
                if (existingGroup) {
                  // Update the existing entry
                  existingGroup.occurance += 1;
                  existingGroup.weight += 1;
                } else {
                  // Add new word group
                  wordGroupsMap.set(key, {
                    prev_id: prevId,
                    next_id: nextId,
                    weight: 1,
                    occurance: 1
                  });
                }
              }
            }
          }

          // When batch size is reached, write to files
          if (wordsBatch.size >= BATCH_SIZE || wordsMap.size >= BATCH_SIZE || wordGroupsMap.size >= BATCH_SIZE) {
            // Write words to text file
            await writeWordsBatchToFile(
              Array.from(wordsBatch),
              wordsWriteStream
            );
            
            // Write words to JSONL file
            await writeWordsToJsonl(
              Array.from(wordsMap.values()),
              wordsJsonlWriteStream
            );
            
            // Write word groups to JSONL file
            await writeWordGroupsToJsonl(
              Array.from(wordGroupsMap.values()),
              wordGroupsJsonlWriteStream
            );

            totalWordsProcessed += wordsBatch.size;
            totalWordGroupsProcessed += wordGroupsMap.size;

            // Display progress
            displayWordsProgress(
              totalLines,
              processedLines,
              wordsBatch.size,
              totalWordsProcessed,
              totalWordGroupsProcessed
            );

            // Clear the batches after successful write
            wordsBatch = new Set<string>();
            wordsMap = new Map<string, { id: number, text: string, sentence_id: number | null, position: number | null }>();
            wordGroupsMap = new Map<string, { prev_id: number, next_id: number, weight: number, occurance: number }>();
          }

          // Update progress after each line
          processedLines += 1;
          if (processedLines % 100 === 0) {
            displayWordsProgress(
              totalLines,
              processedLines,
              wordsBatch.size,
              totalWordsProcessed,
              totalWordGroupsProcessed
            );
          }
        } catch (error) {
          console.error(`Error processing sentence: ${error}`);
          // Continue with the next line
        }
      }

      // Write any remaining data
      if (wordsBatch.size > 0) {
        await writeWordsBatchToFile(Array.from(wordsBatch), wordsWriteStream);
        totalWordsProcessed += wordsBatch.size;
      }
      
      if (wordsMap.size > 0) {
        await writeWordsToJsonl(Array.from(wordsMap.values()), wordsJsonlWriteStream);
      }
      
      if (wordGroupsMap.size > 0) {
        await writeWordGroupsToJsonl(Array.from(wordGroupsMap.values()), wordGroupsJsonlWriteStream);
        totalWordGroupsProcessed += wordGroupsMap.size;
      }

      // Display final progress
      displayWordsProgress(
        totalLines,
        processedLines,
        wordsBatch.size,
        totalWordsProcessed,
        totalWordGroupsProcessed,
        true
      );

      // Close the file write streams
      wordsWriteStream.end();
      wordsJsonlWriteStream.end();
      wordGroupsJsonlWriteStream.end();

      const elapsedSeconds = (Date.now() - startTime) / 1000;
      console.log(`\nSuccessfully processed words from: ${stdTxtFilePath}`);
      console.log(
        `Processed ${processedLines.toLocaleString()} sentences in ${elapsedSeconds.toFixed(
          2
        )}s`
      );
      console.log(
        `Total words extracted: ${totalWordsProcessed.toLocaleString()}`
      );
      console.log(
        `Total word groups created: ${totalWordGroupsProcessed.toLocaleString()}`
      );
      console.log(`Skipped lines: ${skippedLines.toLocaleString()}`);
      console.log(`Created words text file: ${wordsFilePath}`);
      console.log(`Created words JSONL file: ${wordsJsonlFilePath}`);
      console.log(`Created word groups JSONL file: ${wordGroupsJsonlFilePath}`);
    } catch (error) {
      console.error(`Error in processWordsFromSentences: ${error}`);
      // Close the file write streams
      wordsWriteStream.end();
      wordsJsonlWriteStream.end();
      wordGroupsJsonlWriteStream.end();
    } finally {
      // Ensure the readline interface is closed
      rl.close();
      fileStream.close();
    }
  } catch (error) {
    console.error(`Error processing words for ${source.id}:`, error);
  }
}

/**
 * Display progress for words processing
 */
const displayWordsProgress = (() => {
  // Closure variables to track last update time and progress
  let lastUpdateTime = 0;
  let lastProcessedLines = 0;
  let startTime = Date.now();

  return function (
    totalLines: number,
    processedLines: number,
    currentBatchSize: number,
    totalWordsProcessed: number,
    totalWordGroupsProcessed: number = 0,
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
    console.log("Words Processing Progress");
    console.log(`[${progressBar}] ${progress}%`);
    console.log(
      `Sentences: ${processedLines.toLocaleString()} / ${
        totalLines > 0 ? totalLines.toLocaleString() : "unknown"
      }`
    );
    console.log(`Current batch size: ${currentBatchSize.toLocaleString()}`);
    console.log(
      `Total words processed: ${totalWordsProcessed.toLocaleString()}`
    );
    console.log(
      `Total word groups processed: ${totalWordGroupsProcessed.toLocaleString()}`
    );
    console.log(`Processing rate: ${linesPerSecond.toFixed(2)} sentences/sec`);
    console.log(`Elapsed time: ${formatTime(elapsedSeconds)}`);
    console.log(
      `Estimated time remaining: ${formatTime(estimatedTimeRemaining)}`
    );
    console.log(`Last update: ${new Date().toLocaleTimeString()}`);
  };
})();

/**
 * Write a batch of words to a text file
 */
async function writeWordsBatchToFile(
  words: string[],
  writeStream: NodeJS.WritableStream
): Promise<void> {
  // Skip empty batches
  if (words.length === 0) {
    return;
  }

  return new Promise((resolve, reject) => {
    // Sort words alphabetically for better organization
    const sortedWords = [...words].sort();

    // Write each word on a new line
    for (const word of sortedWords) {
      writeStream.write(`${word}\n`);
    }

    // Add a separator between batches for better readability
    writeStream.write(`\n`);

    resolve();
  });
}

/**
 * Write a batch of words to a JSONL file
 */
async function writeWordsToJsonl(
  words: Array<{ id: number, text: string, sentence_id: number | null, position: number | null }>,
  writeStream: NodeJS.WritableStream
): Promise<void> {
  // Skip empty batches
  if (words.length === 0) {
    return;
  }

  return new Promise((resolve, reject) => {
    // Write each word as a JSON line
    for (const word of words) {
      writeStream.write(`${JSON.stringify(word)}\n`);
    }

    resolve();
  });
}

/**
 * Write a batch of word groups to a JSONL file
 */
async function writeWordGroupsToJsonl(
  wordGroups: Array<{ prev_id: number, next_id: number, weight: number, occurance: number }>,
  writeStream: NodeJS.WritableStream
): Promise<void> {
  // Skip empty batches
  if (wordGroups.length === 0) {
    return;
  }

  return new Promise((resolve, reject) => {
    // Write each word group as a JSON line
    for (const wordGroup of wordGroups) {
      writeStream.write(`${JSON.stringify(wordGroup)}\n`);
    }

    resolve();
  });
}
