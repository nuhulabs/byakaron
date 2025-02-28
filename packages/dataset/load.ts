import { prisma } from "@bngc/db";
import { ASSET_PATH } from "./constant";
import { readdir, readFile } from "node:fs/promises";
import { $ } from "bun";

async function handler() {
  const sources = await prisma.datasources.findMany();
  const assetFiles = await readdir(ASSET_PATH, {recursive: true});

  for (const source of sources) {
    const file = assetFiles.find((file) => file.startsWith(`${source.id}_`));
    if (!file) {
      console.log(`File not found for source ${source.id}`);
      continue;
    }

    const filePath = `${ASSET_PATH}/${file}`;
    
    console.log(`Loading ${filePath}`);

    if (source.type === 'mysql_dump') {
      try {
        // First, preprocess the MySQL dump to be PostgreSQL compatible
        console.log('Converting MySQL dump to PostgreSQL format...');
        
        // Create a temporary file for the converted SQL
        const tempFile = `${filePath}.pg.sql`;
        
        // Read the MySQL dump and convert it to PostgreSQL format
        // This uses sed to perform common MySQL to PostgreSQL syntax conversions
        await $`cat ${filePath} | \
          sed 's/ ENGINE=InnoDB//g' | \
          sed 's/ AUTO_INCREMENT/ SERIAL/g' | \
          sed 's/ CHARSET=[^ ]*//g' | \
          sed 's/ unsigned / /g' | \
          sed 's/\`//g' > ${tempFile}`;

        // Read the converted SQL file
        console.log('Loading converted dump into PostgreSQL...');
        const sqlContent = await readFile(tempFile, 'utf-8');
        
        // Split the SQL content into individual statements
        const statements = sqlContent
          .split(';')
          .map(stmt => stmt.trim())
          .filter(stmt => stmt.length > 0);

        // Execute each statement
        for (const statement of statements) {
          try {
            await prisma.$executeRawUnsafe(`${statement};`);
          } catch (err) {
            console.error('Error executing statement:', err);
            console.error('Failed statement:', statement);
          }
        }
        
        console.log('Successfully loaded MySQL dump into PostgreSQL');
        
        // Clean up temporary file
        await $`rm ${tempFile}`;
      } catch (error) {
        console.error('Error loading MySQL dump:', error);
      }
    }
  }
}

handler();
