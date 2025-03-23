import { DATA_SOURCES } from "./constant";

export interface TransformOptions {
  inputFile: string;
  outputFile: string;
  maxPages?: number;
  batchSize?: number;
  verbose?: boolean;
}

export type DataSource = (typeof DATA_SOURCES)[number];
