import fs from 'fs';
import path from 'path';
import { createReadStream, createWriteStream } from 'fs';
import { Transform } from 'stream';
import { pipeline } from 'stream/promises';

// Define paths
const inputFilePath = path.resolve(__dirname, '../assets/1/words.csv');
const outputFilePath = path.resolve(__dirname, '../assets/1/words_pairs_distinct.csv');

async function processCSV() {
  try {
    // Get file size for progress tracking
    const stats = fs.statSync(inputFilePath);
    const fileSizeInBytes = stats.size;
    const fileSizeInMB = fileSizeInBytes / (1024 * 1024);
    console.log(`Processing file: ${inputFilePath}`);
    console.log(`File size: ${fileSizeInMB.toFixed(2)} MB`);

    // Map to store word pairs and their occurrence counts
    const wordPairCounts = new Map<string, number>();
    
    // Track progress
    let bytesProcessed = 0;
    let lastReportedProgress = 0;
    
    // Create a transform stream to process the CSV data
    const processLineStream = new Transform({
      objectMode: true,
      transform(chunk: Buffer, encoding, callback) {
        const line = chunk.toString().trim();
        
        // Update progress
        bytesProcessed += chunk.length;
        const progressPercent = Math.floor((bytesProcessed / fileSizeInBytes) * 100);
        const progressMB = bytesProcessed / (1024 * 1024);
        
        // Report progress every 5%
        if (progressPercent >= lastReportedProgress + 5) {
          console.log(`Processed ${progressMB.toFixed(2)} MB (${progressPercent}%)`);
          lastReportedProgress = progressPercent;
        }
        
        // Skip header line and empty lines
        if (line && !line.startsWith('value,next_value') && line !== '') {
          // Simple CSV parsing - split by comma
          const [value, nextValue] = line.split(',').map(item => item.trim());
          
          if (value && nextValue) {
            // Create a unique key for the word pair
            const pairKey = `${value},${nextValue}`;
            
            // Increment the count for this pair
            wordPairCounts.set(pairKey, (wordPairCounts.get(pairKey) || 0) + 1);
          }
        }
        
        callback();
      }
    });
    
    // Create line splitter stream
    const lineSplitter = new Transform({
      readableObjectMode: true,
      writableObjectMode: false,
      transform(chunk, encoding, callback) {
        const lines = chunk.toString().split('\n');
        for (const line of lines) {
          if (line.trim()) this.push(Buffer.from(line));
        }
        callback();
      }
    });
    
    // Process the file
    await pipeline(
      createReadStream(inputFilePath),
      lineSplitter,
      processLineStream
    );

    
    console.log(`\nProcessing complete!`);
    console.log(`Found ${wordPairCounts.size} unique word pairs`);
    
    // Write word pairs with counts to output file
    console.log(`Writing word pairs with counts to ${outputFilePath}`);
    
    // Create a transform stream to handle the word pairs
    const writePairsStream = new Transform({
      objectMode: true,
      transform(pair, encoding, callback) {
        const [pairKey, count] = pair;
        callback(null, `${pairKey},${count}\n`);
      }
    });
    
    // Setup for tracking write progress
    const totalPairs = wordPairCounts.size;
    let pairsWritten = 0;
    let lastReportedWriteProgress = 0;
    
    // Create a transform stream to track progress
    const progressStream = new Transform({
      transform(chunk, encoding, callback) {
        // Update and report progress
        pairsWritten++;
        const writeProgressPercent = Math.floor((pairsWritten / totalPairs) * 100);
        
        // Report progress every 5%
        if (writeProgressPercent >= lastReportedWriteProgress + 5) {
          console.log(`Writing progress: ${pairsWritten.toLocaleString()} of ${totalPairs.toLocaleString()} pairs (${writeProgressPercent}%)`);
          lastReportedWriteProgress = writeProgressPercent;
        }
        
        // Pass the chunk through
        callback(null, chunk);
      }
    });
    
    // Use pipeline to properly handle backpressure and stream completion
    await pipeline(
      // Create a readable stream from the Map entries
      (async function* () {
        // First yield the header
        yield 'value,next_value,count\n';
        
        // Then yield each word pair
        for (const entry of wordPairCounts.entries()) {
          yield entry;
        }
      })(),
      writePairsStream,
      progressStream,
      createWriteStream(outputFilePath)
    );
    
    console.log('All data written and file closed successfully!');
    
  } catch (error) {
    console.error('Error processing CSV file:', error);
  }
}

// Run the function
processCSV();
