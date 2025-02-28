import { join } from 'path';
import { existsSync } from 'fs';

// Import the parser function
import './parse-wiki';

console.log('Wiki XML transformation started');
console.log(`Working directory: ${import.meta.dir}`);

// Check if the XML file exists
const xmlFilePath = join(import.meta.dir, '../assets/1_bnwiki-latest-pages-articles.xml');
if (!existsSync(xmlFilePath)) {
  console.error(`Error: XML file not found at ${xmlFilePath}`);
  process.exit(1);
}

// The actual parsing is done in the imported module
console.log('Wiki XML transformation completed'); 