#!/usr/bin/env bun
import { processSentencesToWords } from './word';

async function main() {
  try {
    console.log('Processing sentences to words and word groups...');
    // You can adjust the batch size as needed
    const batchSize = 1000;
    const processResult = await processSentencesToWords(batchSize);
    
    if (!processResult.success) {
      console.error('Failed to process sentences');
      process.exit(1);
    }
    
    console.log('Word processing completed successfully');
  } catch (error) {
    console.error('Error during word processing:', error);
    process.exit(1);
  }
}

main(); 