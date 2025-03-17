import { prisma, type DataTypes } from "@bnkt/db";
import * as tokenization from "@bnkt/tokenization";
import { createReadStream, createWriteStream, existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { readdir  } from "node:fs/promises";
import * as path from "path";
import { extname } from "path";
import { createInterface } from "readline";
import { ASSET_PATH } from "../constant";
import { wikiToStd } from "../transform/wiki-jsonl-to-std";
import { transformWikiXmlToJsonl } from "./wiki-xml-to-jsonl";

// Batch size for file writes
const BATCH_SIZE = 100000;
const SENTENCES_FILE = "sentences.csv";
const WORDS_CSV_FILE = "words.csv";
const STATE_FILE = path.join(ASSET_PATH, "state.json");

// Define state interface
interface ProcessingState {
  sources: {
    [sourceId: string | number]: {
      sentences: {
        totalLines?: number;
        processedLines: number;
        totalSentencesProcessed: number;
        lastUpdated: string;
        completed: boolean;
      };
      words: {
        totalLines?: number;
        processedLines: number;
        totalWordPairsProcessed: number;
        lastUpdated: string;
        completed: boolean;
      };
    };
  };
}

// Type for sentence updates
type SentenceUpdates = Partial<ProcessingState['sources'][string]['sentences']>;

// Type for word updates
type WordUpdates = Partial<ProcessingState['sources'][string]['words']>;

// Initialize or load state
function getState(): ProcessingState {
  try {
    if (existsSync(STATE_FILE)) {
      const stateData = readFileSync(STATE_FILE, 'utf8');
      return JSON.parse(stateData);
    }
  } catch (error) {
    console.error("Error reading state file:", error);
  }
  
  // Return default state if file doesn't exist or has errors
  return { sources: {} };
}

// Save state to file
function saveState(state: ProcessingState): void {
  try {
    writeFileSync(STATE_FILE, JSON.stringify(state, null, 2), 'utf8');
  } catch (error) {
    console.error("Error saving state file:", error);
  }
}

// Get source state or initialize if not exists
function getSourceState(state: ProcessingState, sourceId: string | number): ProcessingState['sources'][string] {
  if (!state.sources[sourceId]) {
    state.sources[sourceId] = {
      sentences: {
        processedLines: 0,
        totalSentencesProcessed: 0,
        lastUpdated: new Date().toISOString(),
        completed: false
      },
      words: {
        processedLines: 0,
        totalWordPairsProcessed: 0,
        lastUpdated: new Date().toISOString(),
        completed: false
      }
    };
  }
  return state.sources[sourceId];
}

// Reset source state
function resetSourceState(state: ProcessingState, sourceId: string | number, type: 'sentences' | 'words'): void {
  if (state.sources[sourceId]) {
    if (type === 'sentences') {
      state.sources[sourceId].sentences = {
        processedLines: 0,
        totalSentencesProcessed: 0,
        lastUpdated: new Date().toISOString(),
        completed: false
      };
    } else if (type === 'words') {
      state.sources[sourceId].words = {
        processedLines: 0,
        totalWordPairsProcessed: 0,
        lastUpdated: new Date().toISOString(),
        completed: false
      };
    }
    saveState(state);
  }
}

// Update state and save to file
function updateState(
  state: ProcessingState, 
  sourceId:   string | number, 
  type: 'sentences' | 'words', 
  updates: SentenceUpdates | WordUpdates
): void {
  const sourceState = getSourceState(state, String(sourceId));
  
  if (type === 'sentences') {
    sourceState.sentences = {
      ...sourceState.sentences,
      ...(updates as SentenceUpdates),
      lastUpdated: new Date().toISOString()
    };
  } else if (type === 'words') {
    sourceState.words = {
      ...sourceState.words,
      ...(updates as WordUpdates),
      lastUpdated: new Date().toISOString()
    };
  }
  
  saveState(state);
}

// Ensure source directory exists
function ensureSourceDir(sourceId: string | number): string {
  const sourceDirPath = path.join(ASSET_PATH, String(sourceId));
  if (!existsSync(sourceDirPath)) {
    mkdirSync(sourceDirPath, { recursive: true });
    console.log(`Created directory for source ${sourceId}: ${sourceDirPath}`);
  }
  return sourceDirPath;
}

// Main handler function
async function handler() {
  try {
    const sources = await prisma.datasources.findMany();
    console.log(`Found ${sources.length} sources to download`);

    // Load current state
    const state = getState();
    console.log("Loaded processing state");

    // Run downloads in parallel using Promise.all
    await Promise.all(sources.map(source => transformFile(source, state)));
    await Promise.all(sources.map(source => processWordsFromSentences(source, state)));
    
    console.log("All transformations completed!");
    
    // Give time for any pending file operations to complete
    await new Promise(resolve => setTimeout(resolve, 1000));
    
    // Explicitly exit the process with success code
    process.exit(0);
  } catch (error) {
    console.error("Error in handler:", error);
    // Exit with error code
    process.exit(1);
  }
}

// Call the handler function
handler().catch(err => {
  console.error("Unhandled error in handler:", err);
  process.exit(1);
});

async function transformFile(source: DataTypes.datasources, state: ProcessingState) {
  try {
    console.log(`Processing: ${source.id} ${source.name}`);
    
    // Ensure source directory exists
    const sourceDirPath = ensureSourceDir(source.id);
    
    // Get or initialize source state
    const sourceState = getSourceState(state, source.id);
    
    // Skip if sentences processing is already completed
    if (sourceState.sentences.completed) {
      console.log(`Sentences processing for source ${source.id} already completed, skipping`);
      return;
    }

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
      jsonlFilePath = path.join(sourceDirPath, `transformed.jsonl`);

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

    const stdTxtFilePath = path.join(sourceDirPath, SENTENCES_FILE);

    // Check if standard file exists
    const fileExists = existsSync(stdTxtFilePath);
    
    // Reset state if output file doesn't exist
    if (!fileExists && sourceState.sentences.processedLines > 0) {
      console.log(`Output file doesn't exist but state shows processing started. Resetting state for source ${source.id}`);
      resetSourceState(state, source.id, 'sentences');
    }
    
    // Check if we should resume processing
    const shouldResume = fileExists && sourceState.sentences.processedLines > 0;
    
    if (fileExists && !shouldResume) {
      console.log(
        `Standard file already exists, skipping processing: ${stdTxtFilePath}`
      );
      // Mark as completed in state
      updateState(state, source.id, 'sentences', { completed: true });
      return;
    }

    // Now process the JSONL file to extract sentences and insert directly to database
    console.log(`Processing JSONL file: ${jsonlFilePath}`);

    // Count total lines for progress tracking
    console.log("Counting total lines in JSONL file...");
    const totalLines = await countFileLines(jsonlFilePath);
    console.log(`Total lines in JSONL file: ${totalLines.toLocaleString()}`);
    
    // Update state with total lines
    updateState(state, source.id, 'sentences', { totalLines });

    // Create a read stream and readline interface for processing the JSONL file line by line
    const fileStream = createReadStream(jsonlFilePath);
    const rl = createInterface({
      input: fileStream,
      crlfDelay: Infinity,
    });

    // Create a write stream for the text file with append mode if resuming
    const txtWriteStream = createWriteStream(stdTxtFilePath, { 
      flags: shouldResume ? 'a' : 'w' 
    });

    let sentencesBatch = new Set<string>();
    let processedLines = sourceState.sentences.processedLines || 0;
    let startTime = Date.now();
    let totalSentencesProcessed = sourceState.sentences.totalSentencesProcessed || 0;
    let currentLine = 0;

    try {
      // Process each line of the JSONL file
      for await (const line of rl) {
        currentLine++;
        
        // Skip already processed lines if resuming
        if (shouldResume && currentLine <= processedLines) {
          continue;
        }
        
        try {
          // Parse the JSON line
          const jsonData = JSON.parse(line);

          const sentences = Array.from(wikiToStd(jsonData));

          // Add unique sentences to the batch
          sentences.forEach((sentence) => sentencesBatch.add(sentence));

          // When batch size is reached, insert to database and write to text file
          if (sentencesBatch.size >= BATCH_SIZE) {
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
            
            // Update state
            updateState(state, source.id, 'sentences', {
              processedLines,
              totalSentencesProcessed
            });

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
            
            // Update state periodically
            if (processedLines % 1000 === 0) {
              updateState(state, source.id, 'sentences', {
                processedLines,
                totalSentencesProcessed
              });
            }
          }
        } catch (error) {
          console.error(`Error processing line: ${error}`);
          // Continue with the next line
        }
      }

      // Insert any remaining sentences
      if (sentencesBatch.size > 0) {
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
      console.log(`Created text file with sentences: ${stdTxtFilePath}`);
      
      // Mark as completed in state
      updateState(state, source.id, 'sentences', {
        processedLines,
        totalSentencesProcessed,
        completed: true
      });
    } catch (error) {
      console.error(`Error in loadSentences: ${error}`);
      
      // Update state with current progress
      updateState(state, source.id, 'sentences', {
        processedLines,
        totalSentencesProcessed
      });

      // Close the text file write stream
      txtWriteStream.end();
    } finally {
      // Ensure the readline interface is closed
      rl.close();
      fileStream.close();
    }

    // After processing sentences, process words
    await processWordsFromSentences(source, state);
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

    // Process sentences with backpressure handling
    let i = 0;
    
    function writeNext() {
      // Continue writing as long as there are sentences and the stream can accept data
      let canContinue = true;
      
      while (i < validSentences.length && canContinue) {
        // Write each sentence on a new line
        canContinue = writeStream.write(`${validSentences[i]}\n`);
        i++;
      }
      
      // If we couldn't write all sentences, wait for drain event
      if (i < validSentences.length) {
        writeStream.once('drain', writeNext);
      } else {
        // All sentences written, add a separator and resolve
        writeStream.write(`\n`, (err) => {
          if (err) {
            reject(err);
          } else {
            resolve();
          }
        });
      }
    }
    
    // Start writing
    writeNext();
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
async function processWordsFromSentences(source: DataTypes.datasources, state: ProcessingState) {
  try {
    console.log(`\nProcessing words from sentences for source: ${source.id}`);
    
    // Ensure source directory exists
    const sourceDirPath = ensureSourceDir(source.id);
    
    // Get or initialize source state
    const sourceState = getSourceState(state, String(source.id));
    
    // Skip if words processing is already completed
    if (sourceState.words.completed) {
      console.log(`Words processing for source ${source.id} already completed, skipping`);
      return;
    }

    // Define file paths
    const stdTxtFilePath = path.join(sourceDirPath, SENTENCES_FILE);
    const wordsFilePath = path.join(sourceDirPath, WORDS_CSV_FILE);

    // Check if words file exists
    const fileExists = existsSync(wordsFilePath);
    
    // Reset state if output file doesn't exist
    if (!fileExists && sourceState.words.processedLines > 0) {
      console.log(`Words file doesn't exist but state shows processing started. Resetting state for source ${source.id}`);
      resetSourceState(state, source.id, 'words');
    }
    
    // Check if we should resume processing
    const shouldResume = fileExists && sourceState.words.processedLines > 0;
    
    // Check if words file already exists and we're not resuming
    if (fileExists && !shouldResume) {
      console.log(
        `Words file already exists, skipping processing: ${wordsFilePath}`
      );
      // Mark as completed in state
      updateState(state, String(source.id), 'words', { completed: true });
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
    
    // Update state with total lines
    updateState(state, String(source.id), 'words', { totalLines });

    // Create read stream and readline interface
    const fileStream = createReadStream(stdTxtFilePath);
    const rl = createInterface({
      input: fileStream,
      crlfDelay: Infinity,
    });

    // Create write stream for the CSV file with append mode if resuming
    const wordsWriteStream = createWriteStream(wordsFilePath, { 
      flags: shouldResume ? 'a' : 'w' 
    });
    
    // Write CSV header if not resuming
    if (!shouldResume) {
      wordsWriteStream.write("value,next_value\n");
    }

    let processedLines = sourceState.words.processedLines || 0;
    let startTime = Date.now();
    let totalWordPairsProcessed = sourceState.words.totalWordPairsProcessed || 0;
    let skippedLines = 0;
    let wordPairsBatch: Array<{value: string, next_value: string}> = [];
    let currentLine = 0;

    try {
      // Process each line of the sentences file
      for await (const line of rl) {
        currentLine++;
        
        // Skip already processed lines if resuming
        if (shouldResume && currentLine <= processedLines) {
          continue;
        }
        
        try {
          // Skip empty lines, comments, or very short lines
          if (!line || line.trim().length < 3 || line.startsWith("#")) {
            skippedLines++;
            processedLines++;
            continue;
          }

          // Extract words from the sentence
          const words = tokenization.tokenizeToWords(line);
          
          // Create word pairs (current word and next word)
          for (let i = 0; i < words.length - 1; i++) {
            const currentWord = words[i];
            const nextWord = words[i + 1];
            
            if (currentWord && nextWord) {
              wordPairsBatch.push({
                value: currentWord,
                next_value: nextWord
              });
            }
          }

          // When batch size is reached, write to file
          if (wordPairsBatch.length >= BATCH_SIZE) {
            // Write word pairs to CSV file
            await writeWordPairsToCsv(wordPairsBatch, wordsWriteStream);

            totalWordPairsProcessed += wordPairsBatch.length;

            // Display progress
            displayWordsProgress(
              totalLines,
              processedLines,
              wordPairsBatch.length,
              totalWordPairsProcessed
            );
            
            // Update state
            updateState(state, String(source.id), 'words', {
              processedLines,
              totalWordPairsProcessed
            });

            // Clear the batch after successful write
            wordPairsBatch = [];
          }

          // Update progress after each line
          processedLines += 1;
          if (processedLines % 100 === 0) {
            displayWordsProgress(
              totalLines,
              processedLines,
              wordPairsBatch.length,
              totalWordPairsProcessed
            );
            
            // Update state periodically
            if (processedLines % 1000 === 0) {
              updateState(state, String(source.id), 'words', {
                processedLines,
                totalWordPairsProcessed
              });
            }
          }
        } catch (error) {
          console.error(`Error processing sentence: ${error}`);
          // Continue with the next line
          processedLines++;
        }
      }

      // Write any remaining data
      if (wordPairsBatch.length > 0) {
        await writeWordPairsToCsv(wordPairsBatch, wordsWriteStream);
        totalWordPairsProcessed += wordPairsBatch.length;
      }

      // Display final progress
      displayWordsProgress(
        totalLines,
        processedLines,
        wordPairsBatch.length,
        totalWordPairsProcessed,
        true
      );

      // Close the file write stream
      wordsWriteStream.end();

      const elapsedSeconds = (Date.now() - startTime) / 1000;
      console.log(`\nSuccessfully processed words from: ${stdTxtFilePath}`);
      console.log(
        `Processed ${processedLines.toLocaleString()} sentences in ${elapsedSeconds.toFixed(
          2
        )}s`
      );
      console.log(
        `Total word pairs extracted: ${totalWordPairsProcessed.toLocaleString()}`
      );
      console.log(`Skipped lines: ${skippedLines.toLocaleString()}`);
      console.log(`Created words CSV file: ${wordsFilePath}`);
      
      // Mark as completed in state
      updateState(state, String(source.id), 'words', {
        processedLines,
        totalWordPairsProcessed,
        completed: true
      });
    } catch (error) {
      console.error(`Error in processWordsFromSentences: ${error}`);
      
      // Update state with current progress
      updateState(state, String(source.id), 'words', {
        processedLines,
        totalWordPairsProcessed
      });
      
      // Close the file write stream
      wordsWriteStream.end();
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
    totalWordPairsProcessed: number,
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
      `Total word pairs processed: ${totalWordPairsProcessed.toLocaleString()}`
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
 * Write a batch of word pairs to a CSV file
 */
async function writeWordPairsToCsv(
  wordPairs: Array<{value: string, next_value: string}>,
  writeStream: NodeJS.WritableStream
): Promise<void> {
  // Skip empty batches
  if (wordPairs.length === 0) {
    return;
  }

  return new Promise((resolve, reject) => {
    // Process each word pair
    const processWordPairs = () => {
      let i = 0;
      
      function writeNext() {
        // Continue writing as long as there are pairs and the stream can accept data
        let canContinue = true;
        
        while (i < wordPairs.length && canContinue) {
          const pair = wordPairs[i];
          
          // Escape commas and quotes in the words
          const escapedValue = pair.value.replace(/"/g, '""');
          const escapedNextValue = pair.next_value.replace(/"/g, '""');
          
          // Write the CSV line with proper quoting if needed
          const needsQuotes = escapedValue.includes(',') || escapedNextValue.includes(',');
          const line = needsQuotes 
            ? `"${escapedValue}","${escapedNextValue}"\n`
            : `${escapedValue},${escapedNextValue}\n`;
          
          // Write to stream and check if we need to wait for drain
          canContinue = writeStream.write(line);
          i++;
        }
        
        // If we couldn't write all pairs, wait for drain event
        if (i < wordPairs.length) {
          writeStream.once('drain', writeNext);
        } else {
          // All pairs written, resolve the promise
          resolve();
        }
      }
      
      // Start writing
      writeNext();
    };
    
    // Start processing
    processWordPairs();
  });
}
