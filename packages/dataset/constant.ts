import { join } from "path";

// Base paths
export const ASSET_PATH = "./assets";
export const STATE_FILE_PATH = join(ASSET_PATH, "state.json");
export const BASE_DATA_FILE_PATH = join(ASSET_PATH, "base.jsonl");

// File names for processing steps
export const SENTENCES_FILE = "sentences.csv";
export const WORDS_CSV_FILE = "words.csv";
export const DISTINCT_WORDS_FILE = "words_unique.csv";
export const DISTINCT_WORD_PAIRS_FILE = "word_pairs_unique.csv";

export const SENTENCE_BATCH_SIZE = 100000;