import { join } from "path";

export const ASSET_PATH = "./assets";
export const STATE_FILE_PATH = join(ASSET_PATH, "state.json");
export const BASE_DATA_FILE_PATH = join(ASSET_PATH, "base.jsonl");
export const SENTENCES_FILE_PATH =  join(ASSET_PATH, `sentences.csv`);
export const WORDS_FILE_PATH =  join(ASSET_PATH, `words.csv`);
