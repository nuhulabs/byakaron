import { join } from 'path';
import { existsSync, mkdirSync } from 'fs';
import { writeFile } from 'fs/promises';

// Define the output directory
const OUTPUT_DIR = join(import.meta.dir, '../output');

// Create output directory if it doesn't exist
if (!existsSync(OUTPUT_DIR)) {
  mkdirSync(OUTPUT_DIR, { recursive: true });
}

// Path to the XML file
const XML_FILE_PATH = join(import.meta.dir, '../assets/1_bnwiki-latest-pages-articles.xml');

// Interface for a Wikipedia page
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
  };
  ns: string;
}

// Helper function to extract content between XML tags
function extractTagContent(xml: string, tag: string): string | null {
  const regex = new RegExp(`<${tag}[^>]*>(.*?)<\\/${tag}>`, 's');
  const match = xml.match(regex);
  return match ? match[1].trim() : null;
}

async function parseWikiXml() {
  console.log('Starting to parse XML file...');
  
  // Read the file in chunks using Bun's streaming API
  const file = Bun.file(XML_FILE_PATH);
  
  // For large files, we'll read it in chunks
  const CHUNK_SIZE = 10 * 1024 * 1024; // 10MB chunks
  const fileSize = file.size;
  
  console.log(`File size: ${(fileSize / (1024 * 1024)).toFixed(2)} MB`);
  
  let buffer = '';
  let pageCount = 0;
  const pages: WikiPage[] = [];
  
  // Process the file in chunks
  for (let position = 0; position < fileSize; position += CHUNK_SIZE) {
    const chunk = await file.slice(position, position + CHUNK_SIZE).text();
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
          
          pages.push(page);
          pageCount++;
          
          console.log(`Processed page ${pageCount}: ${title}`);
          
          // Stop after processing 10 pages
          if (pageCount >= 100000) {
            console.log('Reached 10 pages, stopping parser...');
            break;
          }
        }
      } catch (error) {
        console.error('Error processing page:', error);
        // Continue with the next page
      }
    }
    
    // Stop if we've processed 10 pages
    if (pageCount >= 100000) {
      break;
    }
  }
  
  console.log(`Finished parsing. Processed ${pages.length} pages.`);
  
  // Write the pages to a JSON file
  const outputPath = join(OUTPUT_DIR, 'wiki-pages.json');
  await writeFile(outputPath, JSON.stringify(pages, null, 2));
  console.log(`JSON data written to ${outputPath}`);
}

// Run the parser
parseWikiXml().catch(err => {
  console.error('Failed to parse XML:', err);
  process.exit(1);
}); 