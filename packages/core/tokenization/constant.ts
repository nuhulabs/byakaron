import { sentence_separators, word_separators } from "./assets/chars.json";

export const SENTENCE_SEPARATORS = new Set(Object.values(sentence_separators));
export const WORD_SEPARATORS = new Set(Object.values(word_separators));


export const SENTENCE_SEPARATORS_REGEX = new RegExp(
  `[${Array.from(SENTENCE_SEPARATORS).join("")}]`
);

export const WORD_SEPARATORS_REGEX = new RegExp(
  `[${Array.from(WORD_SEPARATORS).join("")}]+`
);