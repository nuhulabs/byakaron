import { join } from "path";

// Base paths
export const ASSET_PATH = "./assets";
export const STATE_FILE_PATH = join(ASSET_PATH, "state.json");

// File names for processing steps
export const BASE_DATA_FILE = "base.jsonl" as const;
export const SENTENCES_FILE = "sentences.csv" as const;
export const WORDS_CSV_FILE = "words.csv" as const;
export const DISTINCT_WORDS_FILE = "words_unique.csv" as const;
export const DISTINCT_WORD_PAIRS_FILE = "word_pairs_unique.csv" as const;

export const SENTENCE_BATCH_SIZE = 100000 as const;
