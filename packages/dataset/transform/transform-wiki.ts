import { existsSync } from 'fs';
import { join } from 'path';
import wtf from 'wtf_wikipedia';
import { mkdirSync, readFileSync } from 'fs';
import { writeFile, appendFile } from 'fs/promises';
import { cleanupSentences } from './util';

const MAX_PAGES = Infinity;
const PAGE_PROCESSING_TIMEOUT = 30000; // 30 seconds timeout for processing a page
const ERROR_LOG_PATH = join(import.meta.dir, '../output/error.log');

// Add state interface to track progress
interface ProcessState {
  lastPosition: number;
  processedPages: number;
  lastPageId: string;
}

// Function to log errors to file
async function logError(message: string, error?: any): Promise<void> {
  const timestamp = new Date().toISOString();
  const errorDetails = error ? `\n${error.stack || error}` : '';
  const logEntry = `[${timestamp}] ${message}${errorDetails}\n\n`;
  
  try {
    await appendFile(ERROR_LOG_PATH, logEntry);
  } catch (logError) {
    console.error('Failed to write to error log:', logError);
  }
}

// Helper function to create a timeout promise
function createTimeout(ms: number, message: string): Promise<never> {
  return new Promise((_, reject) => {
    setTimeout(() => reject(new Error(`Timeout after ${ms}ms: ${message}`)), ms);
  });
}

// Simple progress display function to replace Ink UI
const displayProgress = (() => {
  // Closure variables to track last update time and progress
  let lastUpdateTime = 0;
  let lastProcessedPages = 0;
  
  return function(
    totalSize: number,
    currentPosition: number,
    processedPages: number,
    maxPages: number,
    currentPage: string,
    force: boolean = false
  ) {
    const now = Date.now();
    const UPDATE_THRESHOLD_MS = 1000; // Update display every 1 second
    const UPDATE_THRESHOLD_PAGES = 5; // Or every 5 pages
    
    // Only update if forced or thresholds are met
    if (!force && 
        now - lastUpdateTime < UPDATE_THRESHOLD_MS && 
        processedPages - lastProcessedPages < UPDATE_THRESHOLD_PAGES) {
      return;
    }
    
    // Update tracking variables
    lastUpdateTime = now;
    lastProcessedPages = processedPages;
    
    const progress = Math.min(100, Math.round((currentPosition / totalSize) * 100));
    const pagesProgress = maxPages !== Infinity ? Math.min(100, Math.round((processedPages / maxPages) * 100)) : 0;
    
    // Create a progress bar
    const barLength = 30;
    const filledLength = Math.round(barLength * progress / 100);
    const progressBar = '█'.repeat(filledLength) + '░'.repeat(barLength - filledLength);
    
    console.clear();
    console.log('Wiki XML Transformation Progress');
    console.log(`[${progressBar}] ${progress}%`);
    console.log(`File: ${(currentPosition / (1024 * 1024)).toFixed(2)}MB / ${(totalSize / (1024 * 1024)).toFixed(2)}MB`);
    console.log(`Pages: ${processedPages} / ${maxPages === Infinity ? '∞' : maxPages} ${maxPages !== Infinity ? `(${pagesProgress}%)` : ''}`);
    console.log(`Current page: ${currentPage}`);
    console.log(`Last update: ${new Date().toLocaleTimeString()}`);
    
    // Calculate processing rate (pages per second)
    // Only show if we have processed some pages
    if (processedPages > 0) {
      console.log(`Processing rate: ${(processedPages / Math.max(1, (now - lastUpdateTime) / 1000)).toFixed(2)} pages/sec`);
    }
  };
})();

async function main() {
  console.log('Wiki XML transformation started');
  console.log(`Working directory: ${import.meta.dir}`);

  // Path to the XML file
  const xmlFilePath = join(import.meta.dir, '../assets/1_bnwiki-latest-pages-articles.xml');

  // Check if the XML file exists
  if (!existsSync(xmlFilePath)) {
    const errorMsg = `Error: XML file not found at ${xmlFilePath}`;
    await logError(errorMsg);
    console.error(errorMsg);
    process.exit(1);
  }

  // Path to the output file
  const outputPath = join(import.meta.dir, '../output/wiki-pages.jsonl');
  
  // Path to the state file for resuming
  const statePath = join(import.meta.dir, '../output/wiki-transform-state.json');

  // Parse the XML file (process 10 pages by default)
  parseWikiXml(xmlFilePath, outputPath, statePath, MAX_PAGES)
    .then(() => {
      console.log('Wiki XML transformation completed');
    })
    .catch(async error => {
      const errorMsg = 'Error during XML transformation';
      await logError(errorMsg, error);
      console.error(errorMsg, error);
      process.exit(1);
    }); 
}

main();

/**
 * Parses a Wikipedia XML dump file
 * @param xmlFilePath Path to the XML file
 * @param outputPath Path to save the JSONL output
 * @param statePath Path to save the state for resuming
 * @param maxPages Maximum number of pages to process
 */
async function parseWikiXml(
  xmlFilePath: string,
  outputPath: string,
  statePath: string,
  maxPages: number
): Promise<void> {
  console.log('Starting to parse XML file...');
  
  // Ensure output directory exists
  const outputDir = outputPath.substring(0, outputPath.lastIndexOf('/'));
  if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });
  
  // Read the file in chunks using Bun's streaming API
  const InputFile = Bun.file(xmlFilePath);
  const fileSize = InputFile.size;
  
  console.log(`File size: ${(fileSize / (1024 * 1024)).toFixed(2)} MB`);
  console.log(`Will process up to ${maxPages} pages`);
  console.log(`Page processing timeout: ${PAGE_PROCESSING_TIMEOUT}ms`);
  
  // Check for existing state to resume from
  let initialState: ProcessState = {
    lastPosition: 0,
    processedPages: 0,
    lastPageId: ''
  };
  
  let appendMode = false;
  
  if (existsSync(statePath)) {
    try {
      const stateData = readFileSync(statePath, 'utf-8');
      initialState = JSON.parse(stateData);
      appendMode = true;
      console.log(`Resuming from position ${initialState.lastPosition}, page count ${initialState.processedPages}`);
    } catch (error) {
      const errorMsg = 'Error reading state file, starting from beginning';
      await logError(errorMsg, error);
      console.error(errorMsg, error);
    }
  }
  
  // Create/truncate or open for append the output file
  if (!appendMode) {
    await writeFile(outputPath, '');
  }
  
  const OutputFile = Bun.file(outputPath);
  const outputFileWriter = OutputFile.writer();
  
  // For large files, we'll read it in chunks
  const CHUNK_SIZE = 5 * 1024 * 1024; // 5MB chunks (smaller to avoid memory issues)
  
  let buffer = '';
  let pageCount = initialState.processedPages;
  let position = initialState.lastPosition;
  let currentPageTitle = '';
  
  // Set up initial progress display instead of Ink UI
  displayProgress(fileSize, position, pageCount, maxPages, currentPageTitle, true);
  
  // Process the file in chunks
  try {
    while (position < fileSize && pageCount < maxPages) {
      // Save state periodically (every 10 pages)
      if (pageCount % 10 === 0 && pageCount > initialState.processedPages) {
        const state: ProcessState = {
          lastPosition: position,
          processedPages: pageCount,
          lastPageId: currentPageTitle
        };
        await writeFile(statePath, JSON.stringify(state, null, 2));
      }
      
      // Update the progress display (will only update based on thresholds)
      displayProgress(fileSize, position, pageCount, maxPages, currentPageTitle);
      
      const chunkEnd = Math.min(position + CHUNK_SIZE, fileSize);
      const chunk = await InputFile.slice(position, chunkEnd).text();
      buffer += chunk;
      position = chunkEnd;
      
      // Extract complete page elements from the buffer
      while (true) {
        const pageStartIndex = buffer.indexOf('<page>');
        if (pageStartIndex === -1) break;
        
        const pageEndIndex = buffer.indexOf('</page>', pageStartIndex);
        if (pageEndIndex === -1) {
          // If we don't have a complete page, move position back to ensure we don't miss anything
          if (position > CHUNK_SIZE) {
            position -= buffer.length;
            buffer = '';
          }
          break;
        }
        
        // Extract the complete page XML
        const pageXml = buffer.substring(pageStartIndex, pageEndIndex + 7); // 7 is the length of '</page>'
        
        // Remove the processed page from the buffer
        buffer = buffer.substring(pageEndIndex + 7);
        
        try {
          // Extract basic page info for identification in case of errors
          const pageTitle = extractTagContent(pageXml, 'title') || 'Unknown';
          const pageId = extractTagContent(pageXml, 'id') || 'Unknown';
          currentPageTitle = pageTitle;
          
          // Process the page with timeout
          await Promise.race([
            processPage(pageXml, outputFileWriter),
            createTimeout(PAGE_PROCESSING_TIMEOUT, `Processing page "${pageTitle}" (ID: ${pageId})`)
          ]);
          
          pageCount++;
          console.log(`Processed page ${pageCount}: ${pageTitle}`);
          
          // Stop after processing maxPages pages
          if (pageCount >= maxPages) {
            console.log(`Reached ${maxPages} pages, stopping parser...`);
            break;
          }
        } catch (error: any) {
          const isTimeout = error.message && error.message.includes('Timeout after');
          const errorType = isTimeout ? 'TIMEOUT ERROR' : 'PROCESSING ERROR';
          const errorMsg = `${errorType} on page "${currentPageTitle}" at position ${position}`;
          
          await logError(errorMsg, error);
          console.error(errorMsg);
          
          // Continue with the next page
        }
      }
      
      // If buffer gets too large, trim it to avoid memory issues
      if (buffer.length > CHUNK_SIZE * 2) {
        buffer = buffer.substring(buffer.length - CHUNK_SIZE);
      }
    }
  } catch (error: any) {
    await logError(`Fatal error during XML parsing at position ${position}`, error);
    throw error; // Re-throw to be caught by the main function
  } finally {
    // Save final state
    const finalState: ProcessState = {
      lastPosition: position,
      processedPages: pageCount,
      lastPageId: currentPageTitle
    };
    await writeFile(statePath, JSON.stringify(finalState, null, 2));
    
    // Close the output file
    outputFileWriter.flush();
    outputFileWriter.end();
    
    // Final progress display (force update)
    displayProgress(fileSize, position, pageCount, maxPages, currentPageTitle, true);
  }
  
  console.log(`Finished parsing. Processed ${pageCount} pages.`);
  console.log(`JSONL data written to ${outputPath}`);
  console.log(`Error logs written to ${ERROR_LOG_PATH}`);
}

/**
 * Process a single page XML and write to output
 * @param pageXml The XML content of the page
 * @param outputFileWriter The file writer to write output
 */
async function processPage(pageXml: string, outputFileWriter: any): Promise<void> {
  // Extract page data
  const title = extractTagContent(pageXml, 'title');
  const id = extractTagContent(pageXml, 'id');
  const ns = extractTagContent(pageXml, 'ns');
  
  if (!title || !id || !ns) {
    throw new Error('Missing required page data (title, id, or namespace)');
  }
  
  // Extract revision data
  const revisionXml = extractTagContent(pageXml, 'revision');
  if (!revisionXml) {
    throw new Error('Missing revision data');
  }
  
  const revisionId = extractTagContent(revisionXml, 'id');
  const timestamp = extractTagContent(revisionXml, 'timestamp');
  
  // Extract contributor data
  const contributorXml = extractTagContent(revisionXml, 'contributor');
  let contributor = {};
  
  if (contributorXml) {
    const username = extractTagContent(contributorXml, 'username');
    const contributorId = extractTagContent(contributorXml, 'id');
    const ip = extractTagContent(contributorXml, 'ip');
    
    contributor = {
      ...(username && { username }),
      ...(contributorId && { id: contributorId }),
      ...(ip && { ip })
    };
  }
  
  // Extract text content
  const text = extractTagContent(revisionXml, 'text') || '';
  
  // Convert wikitext to plain text
  const plainText = await wikitextToPlainText(text);
  const sentences = cleanupSentences(plainText);
  
  // Create the page object
  const page: WikiPage = {
    title,
    id,
    ns,
    revision: {
      id: revisionId || '',
      timestamp: timestamp || '',
      text,
      ...(Object.keys(contributor).length > 0 && { contributor })
    }
  };

  const sentencesesObj: Sentences = {
    ts: timestamp ? Date.parse(timestamp) : Date.now(),
    id: `${title}:${id}:${revisionId}`,
    sentences: Array.from(sentences)
  }
    
  const hasNoSentences = sentences.size === 0;
  const isMediaWikiPage = page.title.startsWith('মিডিয়াউইকি:');
  const isTemplatePage = page.title.startsWith('টেমপ্লেট');
  const isMainPage = page.title === 'প্রধান পাতা';
  
  // Write the page to the JSONL file immediately
  if (!hasNoSentences && !isMediaWikiPage && !isTemplatePage && !isMainPage) {
    outputFileWriter.write(JSON.stringify(sentencesesObj) + '\n');
    outputFileWriter.flush();
  }
}

// Helper function to extract content between XML tags
function extractTagContent(xml: string, tag: string): string | null {
  const regex = new RegExp(`<${tag}[^>]*>(.*?)<\\/${tag}>`, 's');
  const match = xml.match(regex);
  return match ? match[1].trim() : null;
}

// Helper function to convert wikitext to plain text
async function wikitextToPlainText(wikitext: string): Promise<string> {
  try {
    const doc = wtf(wikitext);
    return doc.text();
  } catch (error) {
    await logError('Error converting wikitext to plain text', error);
    return wikitext; // Return original text if conversion fails
  }
}

interface WikiPage {
  title: string;
  id: string;
  revision: {
    id: string;
    timestamp: string;
    contributor?: {
      username?: string;
      id?: string;
      ip?: string;
    };
    text: string;
    // sentences: string[]; // Added sentences field
  };
  ns: string;
}

interface Sentences {
  ts: number;
  id: string;
  sentences: string[];
}