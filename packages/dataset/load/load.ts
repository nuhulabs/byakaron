import { createReadStream, existsSync, statSync } from "fs";
import { readdir } from "node:fs/promises";
import * as path from "path";
import { Client } from "pg";
import { from as copyFrom } from "pg-copy-streams";
import { pipeline } from "stream/promises";

import * as Constants from "../constant";
import type { DataSource } from "../types";

async function handler() {
  try {
    console.log("Starting dataset loading process...");

    const sources = Constants.DATA_SOURCES;
    console.log(`Found ${sources.length} data sources to process`);

    if (sources.length === 0) {
      console.log("No data sources found. Exiting.");
      return;
    }

    const assetFiles = await readdir(Constants.ASSET_PATH, { recursive: true });
    console.log(`Found ${assetFiles.length} files in asset directory`);

    for (const source of sources) {
      await loadSentences(source);
      await loadWords(source);
      await loadWordPairs(source);
    }
  } catch (error) {
    console.error("Fatal error in dataset loading process:", error);
    process.exit(1);
  }
}

// Start the handler function and catch any unhandled errors
handler().catch((error) => {
  console.error("Unhandled error in handler:", error);
  process.exit(1);
});

async function loadSentences(source: DataSource) {
  const stdTxtFilePath = path.join(
    Constants.SOURCE_ASSET_PATH(source),
    Constants.SENTENCES_FILE,
  );

  // Check if the standard text file exists
  if (!existsSync(stdTxtFilePath)) {
    console.log(`Standard text file not found: ${stdTxtFilePath}`);
    return;
  }

  console.log(
    `Loading sentences from ${stdTxtFilePath} for source ${source.id}`,
  );

  // Get file size for progress tracking
  const fileStats = statSync(stdTxtFilePath);
  const fileSize = fileStats.size;
  console.log(`File size: ${(fileSize / (1024 * 1024)).toFixed(2)} MB`);

  // Get a direct connection to the database
  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl) {
    throw new Error("DATABASE_URL environment variable is not set");
  }

  // Create a new PostgreSQL client
  const pgClient = new Client(databaseUrl);
  await pgClient.connect();

  try {
    console.log("Connected to PostgreSQL database");

    // Start time for performance tracking
    const startTime = Date.now();

    // Start a transaction
    await pgClient.query("BEGIN");

    // Create a temporary table to hold the data
    console.log("Creating temporary table...");
    await pgClient.query(`
      CREATE TEMP TABLE IF NOT EXISTS temp_sentences (
        text TEXT NULL
      )
    `);

    // Use COPY command to bulk load data from the file
    console.log("Starting COPY operation from file to temp table...");

    // Create a read stream for the file
    const fileStream = createReadStream(stdTxtFilePath);

    // Use the COPY FROM STDIN command with pg-copy-streams
    // Use CSV format with a custom delimiter that's not a newline
    const copyStreamQuery = copyFrom(`
      COPY temp_sentences (text) 
      FROM STDIN 
      WITH (FORMAT TEXT)
    `);

    // Type assertion to make TypeScript happy
    const copyStream = pgClient.query(copyStreamQuery as any);

    // Set up progress tracking
    let bytesProcessed = 0;
    let lastProgressUpdate = 0;

    fileStream.on("data", (chunk) => {
      bytesProcessed += chunk.length;

      // Only update progress display every 100ms to avoid console flickering
      const now = Date.now();
      if (now - lastProgressUpdate > 100) {
        displayProgress(fileSize, bytesProcessed, "COPY Progress");
        lastProgressUpdate = now;
      }
    });

    // Pipe the file stream to the copy stream
    // Type assertion to make TypeScript happy
    await pipeline(fileStream, copyStream as any);

    // Ensure we show 100% at the end
    displayProgress(fileSize, fileSize, "COPY Progress");
    console.log("\nCOPY operation completed");

    // Count the number of rows in the temporary table
    const countResult = await pgClient.query(
      "SELECT COUNT(*) FROM temp_sentences",
    );
    const rowCount = parseInt(countResult.rows[0].count);
    console.log(
      `Loaded ${rowCount.toLocaleString()} rows into temporary table`,
    );

    // Insert distinct sentences into the sentences table
    console.log("Inserting distinct sentences into the sentences table...");

    // Insert in batches with progress tracking
    const batchResult = pgClient.query(
      `
        INSERT INTO warehouse.sentences (text, created_at, datasource_id)
        SELECT DISTINCT text, NOW(), $1::integer
        FROM temp_sentences
        WHERE text IS NOT NULL 
          AND LENGTH(TRIM(text)) > 3
          AND text NOT LIKE '#%'  -- Skip comment lines
          AND text NOT LIKE ''    -- Skip empty lines
      `,
      [source.id],
    );

    // Commit the transaction
    await pgClient.query("COMMIT");

    // Calculate performance metrics
    const endTime = Date.now();
    const elapsedSeconds = (endTime - startTime) / 1000;
    const rowsPerSecond = rowCount / elapsedSeconds;

    console.log(`\nPerformance Summary:`);
    console.log(`Total time: ${elapsedSeconds.toFixed(2)} seconds`);
    console.log(`Processing rate: ${rowsPerSecond.toFixed(2)} rows/second`);
    console.log(
      `File size processed: ${(fileSize / (1024 * 1024)).toFixed(2)} MB`,
    );
    console.log(`Rows loaded: ${rowCount.toLocaleString()}`);
  } catch (error) {
    // Rollback the transaction in case of error
    try {
      await pgClient.query("ROLLBACK");
    } catch (rollbackError) {
      console.error("Error during rollback:", rollbackError);
    }
    console.error("Error during database operations:", error);
    throw error;
  } finally {
    // Close the PostgreSQL client connection
    await pgClient.end();
    console.log("Database connection closed");
  }
}

/**
 * Load words from CSV file into the words table and calculate word pairs
 * This function now handles both loading unique words and calculating word pairs
 * for better performance by avoiding multiple passes through the data
 */
async function loadWordPairs(source: DataSource) {
  const distinctWordsCsvFilePath = path.join(
    Constants.SOURCE_ASSET_PATH(source),
    Constants.UNIQUE_WORD_PAIRS_FILE,
  );

  if (!existsSync(distinctWordsCsvFilePath))
    return console.log(`No word files found for source ${source.id}`);

  // Create a new PostgreSQL client
  const pgClient = new Client(process.env.DATABASE_URL);
  await pgClient.connect();
  console.log("Connected to PostgreSQL database");

  // Variables for tracking file sizes
  let distinctWordsFileSize = 0;
  try {
    // Get file size for progress tracking
    const distinctWordsFileStats = statSync(distinctWordsCsvFilePath);
    distinctWordsFileSize = distinctWordsFileStats.size;
    console.log(
      `Distinct words file size: ${(
        distinctWordsFileSize /
        (1024 * 1024)
      ).toFixed(2)} MB`,
    );

    // Start a transaction
    await pgClient.query("BEGIN");
    console.log("Creating staging table for distinct word pairs...");
    await pgClient.query(`DROP TABLE IF EXISTS  warehouse.word_pairs`);
    await pgClient.query(`
        CREATE TABLE IF NOT EXISTS warehouse.word_pairs (
          value TEXT NULL,
          next_value TEXT NULL,
          occurance INTEGER DEFAULT 0
        )
      `);

    // Use COPY command to bulk load data from the distinct words file
    console.log(
      "Starting COPY operation from distinct words CSV file to staging table...",
    );

    // Create a read stream for the file
    const distinctWordsFileStream = createReadStream(distinctWordsCsvFilePath);

    // Use the COPY FROM STDIN command with pg-copy-streams
    const distinctWordsCopyStreamQuery = copyFrom(`
        COPY warehouse.word_pairs (value, next_value, occurance) 
        FROM STDIN 
        WITH (FORMAT CSV, HEADER)
      `);

    // Set up progress tracking
    let bytesProcessed = 0;
    let lastProgressUpdate = 0;

    distinctWordsFileStream.on("data", (chunk) => {
      bytesProcessed += chunk.length;

      // Only update progress display every 100ms to avoid console flickering
      const now = Date.now();
      if (now - lastProgressUpdate > 100) {
        displayProgress(distinctWordsFileSize, bytesProcessed, "COPY Progress");
        lastProgressUpdate = now;
      }
    });

    // Pipe the file stream to the copy stream
    await pipeline(
      distinctWordsFileStream,
      pgClient.query(distinctWordsCopyStreamQuery as any),
    );

    // Ensure we show 100% at the end
    displayProgress(
      distinctWordsFileSize,
      distinctWordsFileSize,
      "COPY Progress",
    );
    // Commit the transaction
    await pgClient.query("COMMIT");
    console.log("\nCOPY operation completed for distinct word pairs");

    await pgClient.query("BEGIN");
    // Count the number of rows in the staging table
    const distinctWordsCountResult = await pgClient.query(
      "SELECT COUNT(*) FROM warehouse.word_pairs",
    );
    const distinctWordsCount = parseInt(distinctWordsCountResult.rows[0].count);
    console.log(
      `Loaded ${distinctWordsCount.toLocaleString()} distinct word pairs into staging table`,
    );

    // Insert all distinct words at once into the words table
    console.log("Inserting distinct word pairs into the word pairs table...");

    // Process in batches for better performance and progress tracking
    const batchSize = 10 * 100 * 1000; // 10 * 100k
    console.log(`Processing distinct words in batches of ${batchSize}...`);

    // Get total count for progress tracking
    const totalDistinctWords = parseInt(distinctWordsCountResult.rows[0].count);
    console.log(
      `Found ${totalDistinctWords.toLocaleString()} valid distinct word pairs to process`,
    );

    // Calculate number of batches
    const totalBatches = Math.ceil(totalDistinctWords / batchSize);
    let processedWords = 0;
    let totalInserted = 0;

    for (let batchNum = 0; batchNum < totalBatches; batchNum++) {
      // Display batch progress
      console.log(`Processing batch ${batchNum + 1} of ${totalBatches}...`);

      const batchResult = await pgClient.query(
        `
INSERT INTO
	public.word_pairs (prev_id, next_id, weight, occurance)
SELECT
	current_word.id prev_id,
	next_word.id next_id,
	warehouse.word_pairs.occurance weight,
	warehouse.word_pairs.occurance occurance
FROM
	warehouse.word_pairs
	JOIN public.words current_word ON warehouse.word_pairs.value = current_word.value
	JOIN public.words next_word ON warehouse.word_pairs.next_value = next_word.value
LIMIT
	$1
OFFSET
	$2
ON CONFLICT (prev_id, next_id) DO
UPDATE
SET
	weight = public.word_pairs.weight + EXCLUDED.weight,
	occurance = public.word_pairs.occurance + EXCLUDED.occurance
        `,
        [batchSize, batchNum * batchSize],
      );

      processedWords += batchSize;
      totalInserted += batchResult.rowCount ?? 0;

      // Display progress
      displayProgress(
        totalDistinctWords,
        Math.min(processedWords, totalDistinctWords),
        "Words Insertion Progress",
      );
    }

    console.log(
      `\nInserted ${totalInserted.toLocaleString()} new distinct word pairs`,
    );

    // Commit the transaction
    await pgClient.query("COMMIT");
    console.log("Committed distinct words data");
  } catch (error) {
    // Rollback the transaction in case of error
    try {
      await pgClient.query("ROLLBACK");
    } catch (rollbackError) {
      console.error("Error during rollback:", rollbackError);
    }
    console.error("Error during database operations:", error);
    throw error;
  } finally {
    // Close the PostgreSQL client connection
    await pgClient.end();
    console.log("Database connection closed");
  }
}

/**
 * Load words from CSV file into the words table and calculate word pairs
 * This function now handles both loading unique words and calculating word pairs
 * for better performance by avoiding multiple passes through the data
 */
async function loadWords(source: DataSource) {
  const wordPairCsvFilePath = path.join(
    Constants.SOURCE_ASSET_PATH(source),
    Constants.WORD_PAIRS_FILE,
  );
  const distinctWordsCsvFilePath = path.join(
    Constants.SOURCE_ASSET_PATH(source),
    Constants.UNIQUE_WORD_PAIRS_FILE,
  );

  // Check if the words CSV files exist
  const wordPairsExist = existsSync(wordPairCsvFilePath);
  const distinctWordsExist = existsSync(distinctWordsCsvFilePath);

  if (!wordPairsExist && !distinctWordsExist) {
    console.log(`No word files found for source ${source.id}`);
    return;
  }

  // Get a direct connection to the database
  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl) {
    throw new Error("DATABASE_URL environment variable is not set");
  }

  // Create a new PostgreSQL client
  const pgClient = new Client(databaseUrl);
  await pgClient.connect();

  // Variables for tracking file sizes
  let distinctWordsFileSize = 0;

  try {
    console.log("Connected to PostgreSQL database");

    // Start time for performance tracking
    const startTime = Date.now();

    // Process distinct words first if the file exists
    if (distinctWordsExist) {
      console.log(
        `Loading distinct words from ${distinctWordsCsvFilePath} for source ${source.id}`,
      );

      // Get file size for progress tracking
      const distinctWordsFileStats = statSync(distinctWordsCsvFilePath);
      distinctWordsFileSize = distinctWordsFileStats.size;
      console.log(
        `Distinct words file size: ${(
          distinctWordsFileSize /
          (1024 * 1024)
        ).toFixed(2)} MB`,
      );

      // Start a transaction
      await pgClient.query("BEGIN");

      // Create a staging table for distinct words
      console.log("Creating staging table for distinct words...");
      await pgClient.query(`DROP TABLE IF EXISTS staging_distinct_words`);
      await pgClient.query(`
        CREATE TABLE IF NOT EXISTS staging_distinct_words (
          value TEXT NULL
        )
      `);

      // Use COPY command to bulk load data from the distinct words file
      console.log(
        "Starting COPY operation from distinct words CSV file to staging table...",
      );

      // Create a read stream for the file
      const distinctWordsFileStream = createReadStream(
        distinctWordsCsvFilePath,
      );

      // Use the COPY FROM STDIN command with pg-copy-streams
      const distinctWordsCopyStreamQuery = copyFrom(`
        COPY staging_distinct_words (value) 
        FROM STDIN 
        WITH (FORMAT CSV, HEADER)
      `);

      // Set up progress tracking
      let bytesProcessed = 0;
      let lastProgressUpdate = 0;

      distinctWordsFileStream.on("data", (chunk) => {
        bytesProcessed += chunk.length;

        // Only update progress display every 100ms to avoid console flickering
        const now = Date.now();
        if (now - lastProgressUpdate > 100) {
          displayProgress(
            distinctWordsFileSize,
            bytesProcessed,
            "COPY Progress",
          );
          lastProgressUpdate = now;
        }
      });

      // Pipe the file stream to the copy stream
      await pipeline(
        distinctWordsFileStream,
        pgClient.query(distinctWordsCopyStreamQuery as any),
      );

      // Ensure we show 100% at the end
      displayProgress(
        distinctWordsFileSize,
        distinctWordsFileSize,
        "COPY Progress",
      );
      console.log("\nCOPY operation completed for distinct words");

      // Count the number of rows in the staging table
      const distinctWordsCountResult = await pgClient.query(
        "SELECT COUNT(*) FROM staging_distinct_words",
      );
      const distinctWordsCount = parseInt(
        distinctWordsCountResult.rows[0].count,
      );
      console.log(
        `Loaded ${distinctWordsCount.toLocaleString()} distinct words into staging table`,
      );

      // Insert all distinct words at once into the words table
      console.log("Inserting distinct words into the words table...");

      // Process in batches for better performance and progress tracking
      const batchSize = 100000;
      console.log(`Processing distinct words in batches of ${batchSize}...`);

      // Get total count for progress tracking
      const totalDistinctWords = parseInt(
        distinctWordsCountResult.rows[0].count,
      );
      console.log(
        `Found ${totalDistinctWords.toLocaleString()} valid distinct words to process`,
      );

      // Calculate number of batches
      const totalBatches = Math.ceil(totalDistinctWords / batchSize);
      let processedWords = 0;
      let totalInserted = 0;

      for (let batchNum = 0; batchNum < totalBatches; batchNum++) {
        // Display batch progress
        console.log(`Processing batch ${batchNum + 1} of ${totalBatches}...`);

        const batchResult = await pgClient.query(`
          WITH batch AS (
            SELECT value 
            FROM staging_distinct_words
            WHERE value IS NOT NULL AND LENGTH(TRIM(value)) > 0
            LIMIT ${batchSize} OFFSET ${batchNum * batchSize}
          )
          INSERT INTO public.words (value)
          SELECT value FROM batch
          ON CONFLICT (value) DO NOTHING
          RETURNING value
        `);

        processedWords += batchSize;
        totalInserted += batchResult.rowCount ?? 0;

        // Display progress
        displayProgress(
          totalDistinctWords,
          Math.min(processedWords, totalDistinctWords),
          "Words Insertion Progress",
        );
      }

      console.log(
        `\nInserted ${totalInserted.toLocaleString()} new distinct words`,
      );

      // Commit the transaction
      await pgClient.query("COMMIT");
      console.log("Committed distinct words data");
    }

    // Process word pairs if the file exists
    if (wordPairsExist) {
      console.log(
        `Loading word pairs from ${wordPairCsvFilePath} for source ${source.id}`,
      );

      // Get file size for progress tracking
      const wordPairsFileStats = statSync(wordPairCsvFilePath);
      const wordPairsFileSize = wordPairsFileStats.size;
      console.log(
        `Word pairs file size: ${(wordPairsFileSize / (1024 * 1024)).toFixed(
          2,
        )} MB`,
      );

      // Start a transaction
      await pgClient.query("BEGIN");

      // Create a non-temporary table to hold the word pairs data
      console.log("Creating staging table for word pairs...");
      await pgClient.query(`DROP TABLE IF EXISTS staging_word_pairs`);
      await pgClient.query(`
        CREATE TABLE IF NOT EXISTS staging_word_pairs (
          value TEXT NULL,
          next_value TEXT NULL
        )
      `);

      // Use COPY command to bulk load data from the file
      console.log(
        "Starting COPY operation from word pairs CSV file to staging table...",
      );

      // Create a read stream for the file
      const wordPairsFileStream = createReadStream(wordPairCsvFilePath);

      // Use the COPY FROM STDIN command with pg-copy-streams
      const wordPairsCopyStreamQuery = copyFrom(`
        COPY staging_word_pairs (value, next_value) 
        FROM STDIN 
        WITH (FORMAT CSV, HEADER)
      `);

      // Set up progress tracking
      let bytesProcessed = 0;
      let lastProgressUpdate = 0;

      wordPairsFileStream.on("data", (chunk) => {
        bytesProcessed += chunk.length;

        // Only update progress display every 100ms to avoid console flickering
        const now = Date.now();
        if (now - lastProgressUpdate > 100) {
          displayProgress(wordPairsFileSize, bytesProcessed, "COPY Progress");
          lastProgressUpdate = now;
        }
      });

      // Pipe the file stream to the copy stream
      await pipeline(
        wordPairsFileStream,
        pgClient.query(wordPairsCopyStreamQuery as any),
      );

      // Ensure we show 100% at the end
      displayProgress(wordPairsFileSize, wordPairsFileSize, "COPY Progress");
      console.log("\nCOPY operation completed for word pairs");

      // Count the number of rows in the staging table
      const wordPairsCountResult = await pgClient.query(
        "SELECT COUNT(*) FROM staging_word_pairs",
      );
      const wordPairsCount = parseInt(wordPairsCountResult.rows[0].count);
      console.log(
        `Loaded ${wordPairsCount.toLocaleString()} rows into word pairs staging table`,
      );

      // Commit the transaction to ensure the staging data is saved
      await pgClient.query("COMMIT");
      console.log("Committed word pairs staging data");

      // If we didn't process distinct words, we need to extract words from the pairs
      if (!distinctWordsExist) {
        // Start a new transaction for extracting words from pairs
        await pgClient.query("BEGIN");

        console.log("Extracting and inserting unique words from word pairs...");
        const extractWordsResult = await pgClient.query(`
          INSERT INTO public.words (value)
          SELECT DISTINCT word_value FROM (
            (SELECT value as word_value 
            FROM staging_word_pairs
            WHERE value IS NOT NULL AND LENGTH(TRIM(value)) > 0)
            UNION ALL
            (SELECT next_value as word_value
            FROM staging_word_pairs 
            WHERE next_value IS NOT NULL AND LENGTH(TRIM(next_value)) > 0)
          ) combined_values
          ON CONFLICT (value) DO NOTHING
        `);

        console.log(
          `Inserted ${extractWordsResult.rowCount} unique words from word pairs`,
        );

        // Commit the transaction
        await pgClient.query("COMMIT");
        console.log("Committed unique words from word pairs");
      }

      // Now calculate and insert word pairs
      console.log("Inserting word pairs from the CSV data...");

      // Start a new transaction for word pairs
      await pgClient.query("BEGIN");

      const wordPairsResult = await pgClient.query(`
        INSERT INTO word_pairs (prev_id, next_id, weight, occurance)
        SELECT 
          prev_words.id AS prev_id,
          next_words.id AS next_id,
          1.0 AS weight,
          COUNT(*) AS occurance
        FROM staging_word_pairs twp
        JOIN words AS prev_words ON prev_words.value = twp.value
        JOIN words AS next_words ON next_words.value = twp.next_value
        WHERE 
          twp.value IS NOT NULL AND 
          twp.next_value IS NOT NULL AND
          LENGTH(TRIM(twp.value)) > 0 AND
          LENGTH(TRIM(twp.next_value)) > 0
        GROUP BY prev_words.id, next_words.id
        ON CONFLICT (prev_id, next_id) 
        DO UPDATE SET 
          weight = word_pairs.weight + 1.0,
          occurance = word_pairs.occurance + EXCLUDED.occurance
      `);

      console.log(`Inserted/updated ${wordPairsResult.rowCount} word pairs`);

      // Commit the transaction
      await pgClient.query("COMMIT");

      // Calculate performance metrics
      const endTime = Date.now();
      const elapsedSeconds = (endTime - startTime) / 1000;
      const rowsPerSecond = wordPairsCount / elapsedSeconds;

      console.log(`\nPerformance Summary:`);
      console.log(`Total time: ${elapsedSeconds.toFixed(2)} seconds`);
      console.log(`Processing rate: ${rowsPerSecond.toFixed(2)} rows/second`);
      console.log(
        `Word pairs file size processed: ${(
          wordPairsFileSize /
          (1024 * 1024)
        ).toFixed(2)} MB`,
      );
      if (distinctWordsExist) {
        console.log(
          `Distinct words file size processed: ${(
            distinctWordsFileSize /
            (1024 * 1024)
          ).toFixed(2)} MB`,
        );
      }
      console.log(`Word pairs processed: ${wordPairsResult.rowCount}`);
    }
  } catch (error) {
    // Rollback the transaction in case of error
    try {
      await pgClient.query("ROLLBACK");
    } catch (rollbackError) {
      console.error("Error during rollback:", rollbackError);
    }
    console.error("Error during database operations:", error);
    throw error;
  } finally {
    // Close the PostgreSQL client connection
    await pgClient.end();
    console.log("Database connection closed");
  }
}

/**
 * Display progress for operations
 */
function displayProgress(total: number, current: number, label: string) {
  // Calculate progress percentage
  const progress = Math.min(100, Math.round((current / total) * 100));

  // Create a progress bar
  const barLength = 30;
  const filledLength = Math.round((barLength * progress) / 100);
  const progressBar =
    "█".repeat(filledLength) + "░".repeat(barLength - filledLength);

  // Clear the current line and display progress
  process.stdout.clearLine(0);
  process.stdout.cursorTo(0);

  if (label.includes("COPY")) {
    // For file operations, show MB
    process.stdout.write(
      `${label}: [${progressBar}] ${progress}% | ${(
        current /
        (1024 * 1024)
      ).toFixed(2)}MB / ${(total / (1024 * 1024)).toFixed(2)}MB`,
    );
  } else {
    // For row operations, show row counts
    process.stdout.write(
      `${label}: [${progressBar}] ${progress}% | ${current.toLocaleString()} / ${total.toLocaleString()} rows`,
    );
  }
}
