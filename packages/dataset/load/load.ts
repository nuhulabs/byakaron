import { prisma } from "@bngc/db";
import { ASSET_PATH } from "../constant";
import { readdir } from "node:fs/promises";
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
        console.log('Loading converted dump into PostgreSQL...');
        
        await $`docker compose run --build db-load`;
        
        console.log('Successfully loaded MySQL dump into PostgreSQL');
      } catch (error) {
        console.error('Error loading MySQL dump:', error);
      }
    }

    if (source.type === 'xml') {

    }
  }
}

handler();
