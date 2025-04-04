import * as fs from "fs";
import { createReadStream, createWriteStream, existsSync } from "fs";
import { readdir } from "node:fs/promises";
import * as path from "path";
import { extname } from "path";
import { createInterface } from "readline";
import { Transform } from "stream";
import { pipeline } from "stream/promises";

import * as tokenization from "@bntk/tokenization";

import * as Constants from "../constant";
import { WikipediaTransformer } from "../platforms/wikipedia";
import { StateManager } from "../state";
import type { DataSource } from "../types";
import { countFileLines, displayProgress } from "../util";

// Create state manager instance
const stateManager = new StateManager();

// Main handler function
async function handler() {
  try {
    const sources = Constants.DATA_SOURCES;
    console.log(`Found ${sources.length} sources to download`);

    // Display overall progress
    stateManager.displayOverallProgress(sources);

    // Run downloads in parallel using Promise.all
    await Promise.all(sources.map((source) => writeSentences(source)));

    // Display updated overall progress
    stateManager.displayOverallProgress(sources);

    await Promise.all(sources.map((source) => writeWordPairs(source)));

    // Display updated overall progress
    stateManager.displayOverallProgress(sources);

    await Promise.all(sources.map((source) => writeUniqueWords(source)));

    // Display updated overall progress
    stateManager.displayOverallProgress(sources);

    await Promise.all(sources.map((source) => writeUniqueWordPairs(source)));

    // Display final overall progress
    stateManager.displayOverallProgress(sources, true);

    console.log("All transformations completed!");

    // Give time for any pending file operations to complete
    await new Promise((resolve) => setTimeout(resolve, 1000));

    // Remove explicit process exit
    // process.exit(0);
  } catch (error) {
    console.error("Error in handler:", error);
    // Remove explicit process exit
    // process.exit(1);
  }
}

// Call the handler function
handler().catch((err) => {
  console.error("Unhandled error in handler:", err);
  // Remove explicit process exit
  // process.exit(1);
});

async function writeSentences(source: DataSource) {
  /**
   * Write a batch of sentences to a text file
   */
  async function writeSentenceFile(
    sentences: string[],
    writeStream: NodeJS.WritableStream,
  ): Promise<void> {
    // Skip empty batches
    if (sentences.length === 0) {
      return;
    }

    return new Promise((resolve, reject) => {
      // Filter out empty or very short sentences
      const validSentences = sentences.filter(
        (sentence) => sentence && sentence.trim().length >= 3,
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
          writeStream.once("drain", writeNext);
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

  try {
    console.log(`Processing: ${source.id} ${source.name}`);

    // Ensure source directory exists
    const sourceDirPath = stateManager.ensureSourceDir(source.id);

    // Get or initialize source state
    const sourceState = stateManager.getSourceState(source.id);

    // Skip if sentences processing is already completed
    if (sourceState.sentences.completed) {
      console.log(
        `Sentences processing for source ${source.id} already completed, skipping`,
      );
      return;
    }

    // Find files that start with the source ID in the assets directory
    const assetFiles = await readdir(Constants.ASSET_PATH);
    const sourceFile = assetFiles.find((file) =>
      file.startsWith(`${source.id}_`),
    );

    if (!sourceFile) {
      console.error(`No file found for source ${source.id}`);
      return;
    }

    const sourceFilePath = path.join(Constants.ASSET_PATH, sourceFile);
    console.log(`Found file: ${sourceFilePath}`);

    // Determine if we need to transform the file to JSONL first
    const fileExt = extname(sourceFilePath).toLowerCase();
    let jsonlFilePath = sourceFilePath;

    // If the file is not already in JSONL format, transform it
    if (fileExt !== ".jsonl") {
      jsonlFilePath = path.join(sourceDirPath, Constants.BASE_DATA_FILE);

      // Check if transformed file already exists
      if (existsSync(jsonlFilePath)) {
        console.log(
          `Transformed file already exists, skipping transformation: ${jsonlFilePath}`,
        );
      } else {
        // For wiki XML files, use the wiki transformer
        if (fileExt === ".xml" && source.type === "xml") {
          console.log(
            `Transforming XML to JSONL: ${sourceFilePath} -> ${jsonlFilePath}`,
          );
          await WikipediaTransformer.toJSONL({
            inputFile: sourceFilePath,
            outputFile: jsonlFilePath,
            verbose: true,
          });
        } else {
          // For other file types, implement appropriate transformers
          // This is a placeholder for other file type transformations
          console.log(
            `Transformation for ${fileExt} files not implemented yet`,
          );
          return;
        }
      }
    }

    const stdTxtFilePath = path.join(sourceDirPath, Constants.SENTENCES_FILE);

    // Check if standard file exists
    const fileExists = existsSync(stdTxtFilePath);

    // Reset state if output file doesn't exist
    if (!fileExists && sourceState.sentences.processedLines > 0) {
      console.log(
        `Output file doesn't exist but state shows processing started. Resetting state for source ${source.id}`,
      );
      stateManager.resetSourceState(source.id, "sentences");
    }

    // Check if we should resume processing
    const shouldResume = fileExists && sourceState.sentences.processedLines > 0;

    if (fileExists && !shouldResume) {
      console.log(
        `Standard file already exists, skipping processing: ${stdTxtFilePath}`,
      );
      // Mark as completed in state
      stateManager.updateSourceState(source.id, "sentences", {
        completed: true,
      });
      return;
    }

    // Now process the JSONL file to extract sentences and insert directly to database
    console.log(`Processing JSONL file: ${jsonlFilePath}`);

    // Count total lines for progress tracking
    console.log("Counting total lines in JSONL file...");
    const totalLines = await countFileLines(jsonlFilePath);
    console.log(`Total lines in JSONL file: ${totalLines.toLocaleString()}`);

    // Update state with total lines
    stateManager.updateSourceState(source.id, "sentences", { totalLines });

    // Create a read stream and readline interface for processing the JSONL file line by line
    const fileStream = createReadStream(jsonlFilePath);
    const rl = createInterface({
      input: fileStream,
      crlfDelay: Infinity,
    });

    // Create a write stream for the text file with append mode if resuming
    const txtWriteStream = createWriteStream(stdTxtFilePath, {
      flags: shouldResume ? "a" : "w",
    });

    let sentencesBatch = new Set<string>();
    let processedLines = sourceState.sentences.processedLines || 0;
    let totalSentencesProcessed =
      sourceState.sentences.totalSentencesProcessed || 0;
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

          const sentences = Array.from(
            new Set(WikipediaTransformer.toStd(jsonData)),
          );

          // Add unique sentences to the batch
          sentences.forEach((sentence) => sentencesBatch.add(sentence));

          // When batch size is reached, insert to database and write to text file
          if (sentencesBatch.size >= Constants.SENTENCE_BATCH_SIZE) {
            // Write sentences to text file
            await writeSentenceFile(Array.from(sentencesBatch), txtWriteStream);

            totalSentencesProcessed += sentencesBatch.size;

            // Display progress
            displayProgress({
              title: "JSONL Processing",
              totalItems: totalLines,
              processedItems: processedLines,
              currentBatchSize: sentencesBatch.size,
              additionalStats: [
                {
                  label: "Total sentences processed",
                  value: totalSentencesProcessed,
                },
              ],
            });

            // Update state
            stateManager.updateSourceState(source.id, "sentences", {
              processedLines,
              totalSentencesProcessed,
            });

            // Clear the batch after successful insertion
            sentencesBatch = new Set<string>();
          }

          // Update progress after each line
          processedLines += 1;
          if (processedLines % 100 === 0) {
            displayProgress({
              title: "JSONL Processing",
              totalItems: totalLines,
              processedItems: processedLines,
              currentBatchSize: sentencesBatch.size,
              additionalStats: [
                {
                  label: "Total sentences processed",
                  value: totalSentencesProcessed,
                },
              ],
            });

            // Update state periodically
            if (processedLines % 1000 === 0) {
              stateManager.updateSourceState(source.id, "sentences", {
                processedLines,
                totalSentencesProcessed,
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
        await writeSentenceFile(Array.from(sentencesBatch), txtWriteStream);

        totalSentencesProcessed += sentencesBatch.size;
      }

      // Display final progress
      displayProgress({
        title: "JSONL Processing",
        totalItems: totalLines,
        processedItems: processedLines,
        currentBatchSize: sentencesBatch.size,
        additionalStats: [
          {
            label: "Total sentences processed",
            value: totalSentencesProcessed,
          },
        ],
        force: true,
      });

      // Close the text file write stream
      txtWriteStream.end();
      console.log(`\nSuccessfully processed: ${jsonlFilePath}`);
      console.log(`Created text file with sentences: ${stdTxtFilePath}`);

      // Mark as completed in state
      stateManager.updateSourceState(source.id, "sentences", {
        processedLines,
        totalSentencesProcessed,
        completed: true,
      });
    } catch (error) {
      console.error(`Error in loadSentences: ${error}`);

      // Update state with current progress
      stateManager.updateSourceState(source.id, "sentences", {
        processedLines,
        totalSentencesProcessed,
      });

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
 * Process sentences to extract words and create a words file
 */
async function writeWordPairs(source: DataSource) {
  /**
   * Write a batch of word pairs to a CSV file
   */
  async function writeWordPairsToFile(
    wordPairs: Array<{ value: string; next_value: string }>,
    writeStream: NodeJS.WritableStream,
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

            if (!pair) {
              canContinue = false;
              break;
            }

            // Escape commas and quotes in the words
            const escapedValue = pair.value.replace(/"/g, '""');
            const escapedNextValue = pair.next_value.replace(/"/g, '""');

            // Write the CSV line with proper quoting if needed
            const needsQuotes =
              escapedValue.includes(",") || escapedNextValue.includes(",");
            const line = needsQuotes
              ? `"${escapedValue}","${escapedNextValue}"\n`
              : `${escapedValue},${escapedNextValue}\n`;

            // Write to stream and check if we need to wait for drain
            canContinue = writeStream.write(line);
            i++;
          }

          // If we couldn't write all pairs, wait for drain event
          if (i < wordPairs.length) {
            writeStream.once("drain", writeNext);
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

  try {
    console.log(`\nProcessing words from sentences for source: ${source.id}`);

    // Ensure source directory exists
    const sourceDirPath = stateManager.ensureSourceDir(source.id);

    // Get or initialize source state
    const sourceState = stateManager.getSourceState(String(source.id));

    // Skip if words processing is already completed
    if (sourceState.words.completed) {
      console.log(
        `Words processing for source ${source.id} already completed, skipping`,
      );
      return;
    }

    // Define file paths
    const stdTxtFilePath = path.join(sourceDirPath, Constants.SENTENCES_FILE);
    const wordsFilePath = path.join(sourceDirPath, Constants.WORD_PAIRS_FILE);

    // Check if sentences file exists
    if (!existsSync(stdTxtFilePath)) {
      console.error(`Sentences file not found: ${stdTxtFilePath}`);
      return;
    }

    // Check if words file exists
    const fileExists = existsSync(wordsFilePath);

    // Reset state if output file doesn't exist
    if (!fileExists && sourceState.words.processedLines > 0) {
      console.log(
        `Words file doesn't exist but state shows processing started. Resetting state for source ${source.id}`,
      );
      stateManager.resetSourceState(source.id, "words");
    }

    // Check if we should resume processing
    const shouldResume = fileExists && sourceState.words.processedLines > 0;

    // Check if words file already exists and we're not resuming
    if (fileExists && !shouldResume) {
      console.log(
        `Words file already exists, skipping processing: ${wordsFilePath}`,
      );
      // Mark as completed in state
      stateManager.updateSourceState(String(source.id), "words", {
        completed: true,
      });
      return;
    }

    // Count total lines for progress tracking
    console.log("Counting total sentences in text file...");
    const totalLines = await countFileLines(stdTxtFilePath);
    console.log(`Total sentences in text file: ${totalLines.toLocaleString()}`);

    // Update state with total lines
    stateManager.updateSourceState(String(source.id), "words", { totalLines });

    // Create read stream and readline interface
    const fileStream = createReadStream(stdTxtFilePath);
    const rl = createInterface({
      input: fileStream,
      crlfDelay: Infinity,
    });

    // Create write stream for the CSV file with append mode if resuming
    const wordsWriteStream = createWriteStream(wordsFilePath, {
      flags: shouldResume ? "a" : "w",
    });

    // Write CSV header if not resuming
    if (!shouldResume) {
      wordsWriteStream.write("value,next_value\n");
    }

    let processedLines = sourceState.words.processedLines || 0;
    let totalWordPairsProcessed =
      sourceState.words.totalWordPairsProcessed || 0;
    let skippedLines = 0;
    let wordPairsBatch: Array<{ value: string; next_value: string }> = [];
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
                next_value: nextWord,
              });
            }
          }

          // When batch size is reached, write to file
          if (wordPairsBatch.length >= Constants.SENTENCE_BATCH_SIZE) {
            // Write word pairs to CSV file
            await writeWordPairsToFile(wordPairsBatch, wordsWriteStream);

            totalWordPairsProcessed += wordPairsBatch.length;

            // Display progress
            displayProgress({
              title: "Words Processing",
              totalItems: totalLines,
              processedItems: processedLines,
              currentBatchSize: wordPairsBatch.length,
              additionalStats: [
                {
                  label: "Total word pairs extracted",
                  value: totalWordPairsProcessed,
                },
                {
                  label: "Skipped lines",
                  value: skippedLines,
                },
              ],
            });

            // Update state
            stateManager.updateSourceState(String(source.id), "words", {
              processedLines,
              totalWordPairsProcessed,
            });

            // Clear the batch after successful write
            wordPairsBatch = [];
          }

          // Update progress after each line
          processedLines += 1;
          if (processedLines % 100 === 0) {
            displayProgress({
              title: "Words Processing",
              totalItems: totalLines,
              processedItems: processedLines,
              currentBatchSize: wordPairsBatch.length,
              additionalStats: [
                {
                  label: "Total word pairs extracted",
                  value: totalWordPairsProcessed,
                },
                {
                  label: "Skipped lines",
                  value: skippedLines,
                },
              ],
            });

            // Update state periodically
            if (processedLines % 1000 === 0) {
              stateManager.updateSourceState(String(source.id), "words", {
                processedLines,
                totalWordPairsProcessed,
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
        await writeWordPairsToFile(wordPairsBatch, wordsWriteStream);
        totalWordPairsProcessed += wordPairsBatch.length;
      }

      // Display final progress
      displayProgress({
        title: "Words Processing",
        totalItems: totalLines,
        processedItems: processedLines,
        currentBatchSize: wordPairsBatch.length,
        additionalStats: [
          {
            label: "Total word pairs extracted",
            value: totalWordPairsProcessed,
          },
          {
            label: "Skipped lines",
            value: skippedLines,
          },
        ],
        force: true,
      });

      // Close the file write stream
      wordsWriteStream.end();
      console.log(`\nSuccessfully processed words from: ${stdTxtFilePath}`);
      console.log(`Created words CSV file: ${wordsFilePath}`);

      // Mark as completed in state
      stateManager.updateSourceState(String(source.id), "words", {
        processedLines,
        totalWordPairsProcessed,
        completed: true,
      });
    } catch (error) {
      console.error(`Error in processWordsFromSentences: ${error}`);

      // Update state with current progress
      stateManager.updateSourceState(String(source.id), "words", {
        processedLines,
        totalWordPairsProcessed,
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
 * Process words.csv to extract distinct words
 */
async function writeUniqueWords(source: DataSource) {
  try {
    console.log(`\nProcessing distinct words for source: ${source.id}`);

    // Ensure source directory exists
    const sourceDirPath = stateManager.ensureSourceDir(source.id);

    // Get or initialize source state
    const sourceState = stateManager.getSourceState(String(source.id));

    // Skip if distinct words processing is already completed
    if (sourceState.distinctWords.completed) {
      console.log(
        `Distinct words processing for source ${source.id} already completed, skipping`,
      );
      return;
    }

    // Define file paths
    const wordsFilePath = path.join(sourceDirPath, Constants.WORD_PAIRS_FILE);
    const distinctWordsFilePath = path.join(
      sourceDirPath,
      Constants.UNIQUE_WORDS_FILE,
    );

    // Check if words file exists
    if (!existsSync(wordsFilePath)) {
      console.error(`Words file not found: ${wordsFilePath}`);
      return;
    }

    // Check if distinct words file exists
    const fileExists = existsSync(distinctWordsFilePath);

    // Reset state if output file doesn't exist
    if (!fileExists && sourceState.distinctWords.processedBytes > 0) {
      console.log(
        `Distinct words file doesn't exist but state shows processing started. Resetting state for source ${source.id}`,
      );
      stateManager.resetSourceState(source.id, "distinctWords");
    }

    // Check if distinct words file already exists and we're not resuming
    if (fileExists && !sourceState.distinctWords.processedBytes) {
      console.log(
        `Distinct words file already exists, skipping processing: ${distinctWordsFilePath}`,
      );
      // Mark as completed in state
      stateManager.updateSourceState(String(source.id), "distinctWords", {
        completed: true,
      });
      return;
    }

    // Get file size for progress tracking
    const stats = fs.statSync(wordsFilePath);
    const fileSizeInBytes = stats.size;
    const fileSizeInMB = fileSizeInBytes / (1024 * 1024);
    console.log(`Processing file: ${wordsFilePath}`);
    console.log(`File size: ${fileSizeInMB.toFixed(2)} MB`);

    // Update state with total bytes
    stateManager.updateSourceState(String(source.id), "distinctWords", {
      totalBytes: fileSizeInBytes,
    });

    // Sets to store unique values
    const uniqueValues = new Set<string>();

    // Track progress
    let bytesProcessed = sourceState.distinctWords.processedBytes || 0;
    let lastReportedProgress = Math.floor(
      (bytesProcessed / fileSizeInBytes) * 100,
    );

    // Create a transform stream to process the CSV data
    const processLineStream = new Transform({
      objectMode: true,
      transform(chunk: Buffer, encoding, callback) {
        const line = chunk.toString().trim();

        // Update progress
        bytesProcessed += chunk.length;
        const progressPercent = Math.floor(
          (bytesProcessed / fileSizeInBytes) * 100,
        );
        const progressMB = bytesProcessed / (1024 * 1024);

        // Report progress every 5%
        if (progressPercent >= lastReportedProgress + 5) {
          displayProgress({
            title: "Distinct Words Processing",
            totalItems: fileSizeInBytes,
            processedItems: bytesProcessed,
            additionalStats: [
              {
                label: "Processed MB",
                value: progressMB.toFixed(2),
              },
              {
                label: "Unique words found",
                value: uniqueValues.size,
              },
            ],
          });
          lastReportedProgress = progressPercent;

          // Update state periodically
          stateManager.updateSourceState(String(source.id), "distinctWords", {
            processedBytes: bytesProcessed,
            uniqueWordsCount: uniqueValues.size,
          });
        }

        // Skip header line and empty lines
        if (line && !line.startsWith("value,next_value") && line !== "") {
          // Simple CSV parsing - split by comma
          const [value] = line.split(",").map((item) => item.trim());

          if (value) uniqueValues.add(value);
        }

        callback();
      },
    });

    // Create line splitter stream
    const lineSplitter = new Transform({
      readableObjectMode: true,
      writableObjectMode: false,
      transform(chunk, encoding, callback) {
        const lines = chunk.toString().split("\n");
        for (const line of lines) {
          if (line.trim()) this.push(Buffer.from(line));
        }
        callback();
      },
    });

    // Process the file
    await pipeline(
      createReadStream(wordsFilePath),
      lineSplitter,
      processLineStream,
    );

    // Display final progress
    displayProgress({
      title: "Distinct Words Processing",
      totalItems: fileSizeInBytes,
      processedItems: fileSizeInBytes,
      additionalStats: [
        {
          label: "Processed MB",
          value: (fileSizeInBytes / (1024 * 1024)).toFixed(2),
        },
        {
          label: "Unique words found",
          value: uniqueValues.size,
        },
      ],
      force: true,
    });

    console.log(`\nProcessing complete!`);
    console.log(`Found ${uniqueValues.size} unique values`);

    // Write unique values to output file
    console.log(`Writing unique values to ${distinctWordsFilePath}`);
    const outputStream = createWriteStream(distinctWordsFilePath);

    // Write header
    await new Promise<void>((resolve, reject) => {
      outputStream.write("value\n", (err) => {
        if (err) reject(err);
        else resolve();
      });
    });

    // Write unique values with progress tracking
    const totalValues = uniqueValues.size;
    let valuesWritten = 0;
    const sortedValues = Array.from(uniqueValues).sort();

    for (const value of sortedValues) {
      await new Promise<void>((resolve, reject) => {
        outputStream.write(`${value}\n`, (err) => {
          if (err) reject(err);
          else resolve();
        });
      });

      valuesWritten++;
      if (valuesWritten % 10000 === 0 || valuesWritten === totalValues) {
        displayProgress({
          title: "Writing Distinct Words",
          totalItems: totalValues,
          processedItems: valuesWritten,
          additionalStats: [
            {
              label: "Words written",
              value: valuesWritten,
            },
          ],
        });
      }
    }

    // Close the stream and wait for it to finish
    await new Promise<void>((resolve, reject) => {
      outputStream.end((err: Error | null) => {
        if (err) reject(err);
        else resolve();
      });
    });

    console.log("Writing completed successfully!");

    // Mark as completed in state
    stateManager.updateSourceState(String(source.id), "distinctWords", {
      processedBytes: fileSizeInBytes,
      uniqueWordsCount: uniqueValues.size,
      completed: true,
    });
  } catch (error) {
    console.error(`Error processing distinct words for ${source.id}:`, error);
  }
}

/**
 * Process words.csv to extract distinct word pairs with counts
 */
async function writeUniqueWordPairs(source: DataSource) {
  try {
    console.log(`\nProcessing distinct word pairs for source: ${source.id}`);

    // Ensure source directory exists
    const sourceDirPath = stateManager.ensureSourceDir(source.id);

    // Get or initialize source state
    const sourceState = stateManager.getSourceState(String(source.id));

    // Skip if distinct word pairs processing is already completed
    if (sourceState.distinctWordPairs.completed) {
      console.log(
        `Distinct word pairs processing for source ${source.id} already completed, skipping`,
      );
      return;
    }

    // Define file paths
    const wordsFilePath = path.join(sourceDirPath, Constants.WORD_PAIRS_FILE);
    const distinctWordPairsFilePath = path.join(
      sourceDirPath,
      Constants.UNIQUE_WORD_PAIRS_FILE,
    );

    // Check if words file exists
    if (!existsSync(wordsFilePath)) {
      console.error(`Words file not found: ${wordsFilePath}`);
      return;
    }

    // Check if distinct word pairs file exists
    const fileExists = existsSync(distinctWordPairsFilePath);

    // Reset state if output file doesn't exist
    if (!fileExists && sourceState.distinctWordPairs.processedBytes > 0) {
      console.log(
        `Distinct word pairs file doesn't exist but state shows processing started. Resetting state for source ${source.id}`,
      );
      stateManager.resetSourceState(source.id, "distinctWordPairs");
    }

    // Check if distinct word pairs file already exists and we're not resuming
    if (fileExists && !sourceState.distinctWordPairs.processedBytes) {
      console.log(
        `Distinct word pairs file already exists, skipping processing: ${distinctWordPairsFilePath}`,
      );
      // Mark as completed in state
      stateManager.updateSourceState(String(source.id), "distinctWordPairs", {
        completed: true,
      });
      return;
    }

    // Get file size for progress tracking
    const stats = fs.statSync(wordsFilePath);
    const fileSizeInBytes = stats.size;
    const fileSizeInMB = fileSizeInBytes / (1024 * 1024);
    console.log(`Processing file: ${wordsFilePath}`);
    console.log(`File size: ${fileSizeInMB.toFixed(2)} MB`);

    // Update state with total bytes
    stateManager.updateSourceState(String(source.id), "distinctWordPairs", {
      totalBytes: fileSizeInBytes,
    });

    // Map to store word pairs and their occurrence counts
    const wordPairCounts = new Map<string, number>();

    // Track progress
    let bytesProcessed = sourceState.distinctWordPairs.processedBytes || 0;
    let lastReportedProgress = Math.floor(
      (bytesProcessed / fileSizeInBytes) * 100,
    );

    // Create a transform stream to process the CSV data
    const processLineStream = new Transform({
      objectMode: true,
      transform(chunk: Buffer, encoding, callback) {
        const line = chunk.toString().trim();

        // Update progress
        bytesProcessed += chunk.length;
        const progressPercent = Math.floor(
          (bytesProcessed / fileSizeInBytes) * 100,
        );
        const progressMB = bytesProcessed / (1024 * 1024);

        // Report progress every 5%
        if (progressPercent >= lastReportedProgress + 5) {
          displayProgress({
            title: "Distinct Word Pairs Processing",
            totalItems: fileSizeInBytes,
            processedItems: bytesProcessed,
            additionalStats: [
              {
                label: "Processed MB",
                value: progressMB.toFixed(2),
              },
              {
                label: "Unique pairs found",
                value: wordPairCounts.size,
              },
            ],
          });
          lastReportedProgress = progressPercent;

          // Update state periodically
          stateManager.updateSourceState(
            String(source.id),
            "distinctWordPairs",
            {
              processedBytes: bytesProcessed,
              uniquePairsCount: wordPairCounts.size,
            },
          );
        }

        // Skip header line and empty lines
        if (line && !line.startsWith("value,next_value") && line !== "") {
          // Simple CSV parsing - split by comma
          const [value, nextValue] = line.split(",").map((item) => item.trim());

          if (value && nextValue) {
            // Create a unique key for the word pair
            const pairKey = `${value},${nextValue}`;

            // Increment the count for this pair
            wordPairCounts.set(pairKey, (wordPairCounts.get(pairKey) || 0) + 1);
          }
        }

        callback();
      },
    });

    // Create line splitter stream
    const lineSplitter = new Transform({
      readableObjectMode: true,
      writableObjectMode: false,
      transform(chunk, encoding, callback) {
        const lines = chunk.toString().split("\n");
        for (const line of lines) {
          if (line.trim()) this.push(Buffer.from(line));
        }
        callback();
      },
    });

    // Process the file
    await pipeline(
      createReadStream(wordsFilePath),
      lineSplitter,
      processLineStream,
    );

    // Display final progress
    displayProgress({
      title: "Distinct Word Pairs Processing",
      totalItems: fileSizeInBytes,
      processedItems: fileSizeInBytes,
      additionalStats: [
        {
          label: "Processed MB",
          value: (fileSizeInBytes / (1024 * 1024)).toFixed(2),
        },
        {
          label: "Unique pairs found",
          value: wordPairCounts.size,
        },
      ],
      force: true,
    });

    console.log(`\nProcessing complete!`);
    console.log(`Found ${wordPairCounts.size} unique word pairs`);

    // Write word pairs with counts to output file
    console.log(`Writing word pairs to ${distinctWordPairsFilePath}`);
    const outputStream = createWriteStream(distinctWordPairsFilePath);

    // Write header
    await new Promise<void>((resolve, reject) => {
      outputStream.write("value,next_value,count\n", (err) => {
        if (err) reject(err);
        else resolve();
      });
    });

    // Write word pairs with counts with progress tracking
    const totalPairs = wordPairCounts.size;
    let pairsWritten = 0;
    const sortedPairs = Array.from(wordPairCounts.entries()).sort();

    for (const [pairKey, count] of sortedPairs) {
      await new Promise<void>((resolve, reject) => {
        outputStream.write(`${pairKey},${count}\n`, (err) => {
          if (err) reject(err);
          else resolve();
        });
      });

      pairsWritten++;
      if (pairsWritten % 10000 === 0 || pairsWritten === totalPairs) {
        displayProgress({
          title: "Writing Distinct Word Pairs",
          totalItems: totalPairs,
          processedItems: pairsWritten,
          additionalStats: [
            {
              label: "Pairs written",
              value: pairsWritten,
            },
          ],
        });
      }
    }

    // Close the stream and wait for it to finish
    await new Promise<void>((resolve, reject) => {
      outputStream.end((err: Error | null) => {
        if (err) reject(err);
        else resolve();
      });
    });

    console.log("Writing completed successfully!");

    // Mark as completed in state
    stateManager.updateSourceState(String(source.id), "distinctWordPairs", {
      processedBytes: fileSizeInBytes,
      uniquePairsCount: wordPairCounts.size,
      completed: true,
    });
  } catch (error) {
    console.error(
      `Error processing distinct word pairs for ${source.id}:`,
      error,
    );
  }
}
