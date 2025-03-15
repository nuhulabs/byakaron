import type { DataTypes } from "@bnkt/db";
import { prisma } from "@bnkt/db";
import { createReadStream, existsSync, statSync } from "fs";
import { readdir } from "node:fs/promises";
import * as path from "path";
import { Client } from "pg";
import { ASSET_PATH } from "../constant";
import { from as copyFrom } from "pg-copy-streams";
import { pipeline } from "stream/promises";

async function handler() {
  try {
    console.log("Starting dataset loading process...");
    
    // await measureCopy();
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
  const stdTxtFilePath = path.join(ASSET_PATH, `${source.id}_std.txt`);

  // Check if the standard text file exists
  if (!existsSync(stdTxtFilePath)) {
    console.log(`Standard text file not found: ${stdTxtFilePath}`);
    return;
  }

  console.log(`Loading sentences from ${stdTxtFilePath} for source ${source.id}`);

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
    await pgClient.query('BEGIN');
    
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
    
    fileStream.on('data', (chunk) => {
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
    const countResult = await pgClient.query('SELECT COUNT(*) FROM temp_sentences');
    const rowCount = parseInt(countResult.rows[0].count);
    console.log(`Loaded ${rowCount.toLocaleString()} rows into temporary table`);

    // Insert distinct sentences into the sentences table
    console.log("Inserting distinct sentences into the sentences table...");
    
    // Insert in batches with progress tracking
      const batchResult =  pgClient.query(`
        INSERT INTO sentences (text, created_at, datasource_id)
        SELECT DISTINCT text, NOW(), $1::integer
        FROM temp_sentences
        WHERE text IS NOT NULL 
          AND LENGTH(TRIM(text)) > 3
          AND text NOT LIKE '#%'  -- Skip comment lines
          AND text NOT LIKE ''    -- Skip empty lines
      `, [source.id]);

    // Commit the transaction
    await pgClient.query('COMMIT');


    // Calculate performance metrics
    const endTime = Date.now();
    const elapsedSeconds = (endTime - startTime) / 1000;
    const rowsPerSecond = rowCount / elapsedSeconds;
    
    console.log(`\nPerformance Summary:`);
    console.log(`Total time: ${elapsedSeconds.toFixed(2)} seconds`);
    console.log(`Processing rate: ${rowsPerSecond.toFixed(2)} rows/second`);
    console.log(`File size processed: ${(fileSize / (1024 * 1024)).toFixed(2)} MB`);
    console.log(`Rows loaded: ${rowCount.toLocaleString()}`);
    
  } catch (error) {
    // Rollback the transaction in case of error
    try {
      await pgClient.query('ROLLBACK');
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
  const progressBar = "█".repeat(filledLength) + "░".repeat(barLength - filledLength);
  
  // Clear the current line and display progress
  process.stdout.clearLine(0);
  process.stdout.cursorTo(0);
  
  if (label.includes("COPY")) {
    // For file operations, show MB
    process.stdout.write(`${label}: [${progressBar}] ${progress}% | ${(current / (1024 * 1024)).toFixed(2)}MB / ${(total / (1024 * 1024)).toFixed(2)}MB`);
  } else {
    // For row operations, show row counts
    process.stdout.write(`${label}: [${progressBar}] ${progress}% | ${current.toLocaleString()} / ${total.toLocaleString()} rows`);
  }
}

