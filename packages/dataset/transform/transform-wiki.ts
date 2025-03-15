import { existsSync } from 'fs';
import { join } from 'path';
import wtf from 'wtf_wikipedia';

import { mkdirSync } from 'fs';
import { writeFile } from 'fs/promises';
import { cleanupSentences } from './util';

const MAX_PAGES = Infinity;
async function main() {

console.log('Wiki XML transformation started');
console.log(`Working directory: ${import.meta.dir}`);

// Path to the XML file
const xmlFilePath = join(import.meta.dir, '../assets/1_bnwiki-latest-pages-articles.xml');

// Check if the XML file exists
if (!existsSync(xmlFilePath)) {
  console.error(`Error: XML file not found at ${xmlFilePath}`);
  process.exit(1);
}

// Path to the output file
const outputPath = join(import.meta.dir, '../output/wiki-pages.jsonl');

// Parse the XML file (process 10 pages by default)
parseWikiXml(xmlFilePath, outputPath, MAX_PAGES)
  .then(() => {
    console.log('Wiki XML transformation completed');
  })
  .catch(error => {
    console.error('Error during XML transformation:', error);
    process.exit(1);
  }); 


}

main();



/**
 * Parses a Wikipedia XML dump file
 * @param xmlFilePath Path to the XML file
 * @param outputPath Path to save the JSONL output
 * @param maxPages Maximum number of pages to process
 */
async function parseWikiXml(
  xmlFilePath: string,
  outputPath: string,
  maxPages: number
): Promise<void> {
  console.log('Starting to parse XML file...');
  
  // Ensure output directory exists
  const outputDir = outputPath.substring(0, outputPath.lastIndexOf('/'));
  if (!existsSync(outputDir))mkdirSync(outputDir, { recursive: true });
  // Create/truncate the output file
  await writeFile(outputPath, '');
  
  // Read the file in chunks using Bun's streaming API
  const InputFile = Bun.file(xmlFilePath);
  const OutputFile = Bun.file(outputPath);
  const outputFileWriter = OutputFile.writer();
  
  // For large files, we'll read it in chunks
  const CHUNK_SIZE = 10 * 1024 * 1024; // 10MB chunks
  const fileSize = InputFile.size;
  
  console.log(`File size: ${(fileSize / (1024 * 1024)).toFixed(2)} MB`);
  console.log(`Will process up to ${maxPages} pages`);
  
  let buffer = '';
  let pageCount = 0;
  
  // Process the file in chunks
  for (let position = 0; position < fileSize; position += CHUNK_SIZE) {
    const chunk = await InputFile.slice(position, position + CHUNK_SIZE).text();
    buffer += chunk;
    
    // Extract complete page elements from the buffer
    while (true) {
      const pageStartIndex = buffer.indexOf('<page>');
      if (pageStartIndex === -1) break;
      
      const pageEndIndex = buffer.indexOf('</page>', pageStartIndex);
      if (pageEndIndex === -1) break;
      
      // Extract the complete page XML
      const pageXml = buffer.substring(pageStartIndex, pageEndIndex + 7); // 7 is the length of '</page>'
      
      // Remove the processed page from the buffer
      buffer = buffer.substring(pageEndIndex + 7);
      
      try {
        // Extract page data
        const title = extractTagContent(pageXml, 'title');
        const id = extractTagContent(pageXml, 'id');
        const ns = extractTagContent(pageXml, 'ns');
        
        // Extract revision data
        const revisionXml = extractTagContent(pageXml, 'revision');
        if (!revisionXml) continue;
        
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
        if (title && id && ns) {
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
          if (!hasNoSentences && !isMediaWikiPage && !isTemplatePage && !isMainPage) outputFileWriter.write(JSON.stringify(sentencesesObj) + '\n');
          
          pageCount++;
          
          console.log(`Processed page ${pageCount}: ${title}`);
          
          // Stop after processing maxPages pages
          if (pageCount >= maxPages) {
            console.log(`Reached ${maxPages} pages, stopping parser...`);
            break;
          }
        }
      } catch (error) {
        console.error('Error processing page:', error);
        // Continue with the next page
      }
    }
    
    // Stop if we've processed maxPages pages
    if (pageCount >= maxPages) {
      break;
    }
  }
  
  console.log(`Finished parsing. Processed ${pageCount} pages.`);
  console.log(`JSONL data written to ${outputPath}`);
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
    console.error('Error converting wikitext to plain text:', error);
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