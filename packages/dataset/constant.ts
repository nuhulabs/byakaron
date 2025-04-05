import { join } from "path";

import { datasources } from "./sources.json";
import type { DataSource } from "./types";

// Base paths
export const ASSET_PATH = "./assets";
export const SOURCE_ASSET_PATH = (source: DataSource) =>
  join(ASSET_PATH, `${source.name}`);
export const STATE_FILE_PATH = join(ASSET_PATH, "state.json");

// File names for processing steps
export const BASE_DATA_FILE = "base.jsonl" as const;
export const SENTENCES_FILE = "sentences.csv" as const;
export const WORD_PAIRS_FILE = "word_pairs.csv" as const;
export const UNIQUE_WORDS_FILE = "words_unique.csv" as const;
export const UNIQUE_WORD_PAIRS_FILE = "word_pairs_unique.csv" as const;
export const BANGLISH_WORDS_FILE = "banglish_words.csv" as const;

export const SENTENCE_BATCH_SIZE = 100000 as const;
export const DATA_SOURCES = datasources;
