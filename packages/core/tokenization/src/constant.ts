import { sentence_separators, word_separators } from "../assets/chars.json";

/**
 * Set of Bangla sentence separator characters.
 * These characters are used to identify the end of a sentence in Bangla text.
 * 
 * @example
 * ```typescript
 * const text: string = "আমি বাংলায় গান গাই। তুমি কি শুনবে?";
 * const hasSeparator: boolean = Array.from(SENTENCE_SEPARATORS).some(sep => text.includes(sep));
 * console.log(hasSeparator);
 * // Output: true
 * ```
 */
export const SENTENCE_SEPARATORS = new Set(Object.values(sentence_separators));

/**
 * Set of Bangla word separator characters.
 * These characters are used to identify word boundaries in Bangla text.
 * 
 * @example
 * ```typescript
 * const text: string = "আমি-বাংলায়,গান গাই";
 * const hasSeparator: boolean = Array.from(WORD_SEPARATORS).some(sep => text.includes(sep));
 * console.log(hasSeparator);
 * // Output: true
 * ```
 */
export const WORD_SEPARATORS = new Set(Object.values(word_separators));

/**
 * Regular expression pattern for matching Bangla sentence separators.
 * This pattern is used to split text into sentences.
 * 
 * @example
 * ```typescript
 * const text: string = "আমি বাংলায় গান গাই। তুমি কি শুনবে?";
 * const sentences: string[] = text.split(SENTENCE_SEPARATORS_REGEX);
 * console.log(sentences);
 * // Output: ["আমি বাংলায় গান গাই", "তুমি কি শুনবে"]
 * ```
 */
export const SENTENCE_SEPARATORS_REGEX = new RegExp(
  `[${Array.from(SENTENCE_SEPARATORS).join("")}]`
);

/**
 * Regular expression pattern for matching Bangla word separators.
 * This pattern is used to split text into words.
 * 
 * @example
 * ```typescript
 * const text: string = "আমি-বাংলায়,গান গাই";
 * const words: string[] = text.split(WORD_SEPARATORS_REGEX);
 * console.log(words);
 * // Output: ["আমি", "বাংলায়", "গান", "গাই"]
 * ```
 */
export const WORD_SEPARATORS_REGEX = new RegExp(
  `[${Array.from(WORD_SEPARATORS).join("")}]+`
);