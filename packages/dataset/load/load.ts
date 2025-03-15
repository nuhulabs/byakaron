import { prisma } from "@bngc/db";
import { ASSET_PATH } from "../constant";
import { readdir, access } from "node:fs/promises";
import { $ } from "bun";
import * as path from "path";
import { constants } from "fs";

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

    if (source.type === 'xml') {
      try {
        // Check if sentences file exists
        const sentencesFilePath = path.join(ASSET_PATH, 'sentences', `${source.id}_sentences.txt`);
        
        try {
          await access(sentencesFilePath, constants.R_OK);
        } catch (error) {
          console.error(`Sentences file not found or not readable: ${sentencesFilePath}`);
          continue;
        }
        
        console.log(`Loading sentences from ${sentencesFilePath} into database...`);
        
        // Use Prisma raw query to perform PostgreSQL COPY operation
        // First create a temporary table
        await prisma.$executeRaw`
          CREATE TEMP TABLE temp_sentences (
            text TEXT
          )
        `;
        
        // Use PostgreSQL COPY command to bulk load data from file
        await prisma.$executeRaw`
          COPY temp_sentences (text)
          FROM ${sentencesFilePath}
          WITH (FORMAT text, DELIMITER E'\n')
        `;
        
        // Insert distinct sentences into the sentences table
        const result = await prisma.$executeRaw`
          INSERT INTO sentences (text, datasource_id, created_at)
          SELECT DISTINCT text, ${source.id}, NOW()
          FROM temp_sentences
          ON CONFLICT (text) DO NOTHING
        `;
        
        // Drop the temporary table
        await prisma.$executeRaw`DROP TABLE temp_sentences`;
        
        console.log(`Successfully loaded sentences into database from ${sentencesFilePath}`);
      } catch (error) {
        console.error('Error loading sentences into database:', error);
      }
    }
  }
}

handler();
