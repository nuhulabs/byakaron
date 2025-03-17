import fs from 'fs';
import path from 'path';
import { createReadStream, createWriteStream } from 'fs';
import { Transform } from 'stream';
import { pipeline } from 'stream/promises';

// Define paths
const inputFilePath = path.resolve(__dirname, '../assets/1/words.csv');
const outputFilePath = path.resolve(__dirname, '../assets/1/words_distinct.csv');

async function processCSV() {
  try {
    // Get file size for progress tracking
    const stats = fs.statSync(inputFilePath);
    const fileSizeInBytes = stats.size;
    const fileSizeInMB = fileSizeInBytes / (1024 * 1024);
    console.log(`Processing file: ${inputFilePath}`);
    console.log(`File size: ${fileSizeInMB.toFixed(2)} MB`);

    // Sets to store unique values
    const uniqueValues = new Set<string>();
    const uniqueNextValues = new Set<string>();
    
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
          
          if (value) uniqueValues.add(value);
          if (nextValue) uniqueNextValues.add(nextValue);
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
    console.log(`Found ${uniqueValues.size} unique values`);
    console.log(`Found ${uniqueNextValues.size} unique next_values`);
    
    // Write unique values to output file
    console.log(`Writing unique values to ${outputFilePath}`);
    const outputStream = createWriteStream(outputFilePath);
    
    // Write header
    outputStream.write('value\n');
    
    // Write unique values
    for (const value of uniqueValues) {
      outputStream.write(`${value}\n`);
    }
    
    outputStream.end();
    console.log('Done!');
    
  } catch (error) {
    console.error('Error processing CSV file:', error);
  }
}

// Run the function
processCSV();
