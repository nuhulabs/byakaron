console.log("@bntk/pos");

/**
 * Part-of-Speech (POS) tagging and analysis functions for Bangla text
 */

/**
 * Universal POS tags based on Universal Dependencies (UD) v2 specification
 * Source: https://universaldependencies.org/u/pos/
 */
export const enum UniversalPOSTag {
  /** Adjectives are words that typically modify nouns
   * @example বড়/boro, সুন্দর/sundor, নতুন/notun */
  ADJ = "ADJ",
  /** Adpositions are prepositions and postpositions
   * @example মধ্যে/moddhe, থেকে/theke, উপরে/upore */
  ADP = "ADP",
  /** Adverbs are words that typically modify verbs, adjectives or other adverbs
   * @example খুব/khub, ধীরে/dhire, ভালোভাবে/bhalobhabe */
  ADV = "ADV",
  /** Auxiliary verbs are used to form tenses, moods, etc.
   * @example আছে/ache, হয়/hoi, হবে/hobe */
  AUX = "AUX",
  /** Coordinating conjunctions connect words, phrases, clauses of equal status
   * @example এবং/ebong, কিন্তু/kintu, অথবা/othoba */
  CCONJ = "CCONJ",
  /** Determiners are words that modify nouns or noun phrases
   * @example এই/ei, সেই/sei, কোন/kon */
  DET = "DET",
  /** Interjections are exclamatory words
   * @example ওহ/oh, বাহ/bah, হায়/hay */
  INTJ = "INTJ",
  /** Nouns are words denoting all physical objects and materials
   * @example বই/boi, মানুষ/manush, বাড়ি/bari */
  NOUN = "NOUN",
  /** Numerals represent numbers, quantities, etc.
   * @example এক/ek, দুই/dui, প্রথম/prothom */
  NUM = "NUM",
  /** Particles are function words that must be associated with another word
   * @example না/na, তো/to, কি/ki */
  PART = "PART",
  /** Pronouns substitute for nouns or noun phrases
   * @example আমি/ami, তুমি/tumi, সে/se */
  PRON = "PRON",
  /** Proper nouns are names of specific persons, places, organizations
   * @example ঢাকা/dhaka, রবীন্দ্রনাথ/robindronath, বাংলাদেশ/bangladesh */
  PROPN = "PROPN",
  /** Punctuation marks
   * @example ।, ?, !, , */
  PUNCT = "PUNCT",
  /** Subordinating conjunctions link dependent clauses to independent ones
   * @example যদি/jodi, কারণ/karon, যখন/jokhon */
  SCONJ = "SCONJ",
  /** Symbols represent currency, math operators, etc.
   * @example ৳, +, = */
  SYM = "SYM",
  /** Verbs denote actions and processes
   * @example যাই/jai, খাই/khai, পড়ি/pori */
  VERB = "VERB",
  /** Other words that don't fit into above categories
   * @example ইত্যাদি/ittyadi, প্রভৃতি/probhriti */
  X = "X",
}

/**
 * Represents a word with its POS tag and additional linguistic features
 */
export interface TaggedWord {
  /** The original word */
  word: string;
  /** The POS tag for the word */
  tag: UniversalPOSTag;
  /** Additional linguistic features (e.g., gender, number, case) */
  features?: Record<string, string>;
}

/**
 * Tags a single Bangla word with its part of speech
 *
 * @param {string} word - The Bangla word to tag
 * @returns {TaggedWord} The word with its POS tag and features
 *
 * @description
 * This function performs POS tagging for a single Bangla word.
 * It uses a combination of rules and dictionary lookup to determine
 * the most likely POS tag for the given word.
 *
 * @example
 * ```typescript
 * const result = tagWord("বাংলা");
 * console.log(result);
 * // Output: { word: "বাংলা", tag: UniversalPOSTag.NOUN }
 * ```
 *
 * @example
 * ```typescript
 * const result = tagWord("সুন্দর");
 * console.log(result);
 * // Output: { word: "সুন্দর", tag: UniversalPOSTag.ADJ }
 * ```
 */
export function tagWord(word: string): TaggedWord {
  // TODO: Implement actual POS tagging logic
  return {
    word,
    tag: UniversalPOSTag.NOUN,
  };
}

/**
 * Tags a sequence of Bangla words with their parts of speech
 *
 * @param {string[]} words - Array of Bangla words to tag
 * @returns {TaggedWord[]} Array of words with their POS tags and features
 *
 * @description
 * This function performs POS tagging for a sequence of Bangla words.
 * It takes into account the context of surrounding words to improve
 * tagging accuracy.
 *
 * @example
 * ```typescript
 * const words = ["আমি", "বাংলায়", "গান", "গাই"];
 * const tagged = tagWords(words);
 * console.log(tagged);
 * // Output: [
 * //   { word: "আমি", tag: UniversalPOSTag.PRON },
 * //   { word: "বাংলায়", tag: UniversalPOSTag.ADP },
 * //   { word: "গান", tag: UniversalPOSTag.NOUN },
 * //   { word: "গাই", tag: UniversalPOSTag.VERB }
 * // ]
 * ```
 */
export function tagWords(words: string[]): TaggedWord[] {
  // TODO: Implement actual POS tagging logic
  return words.map((word) => tagWord(word));
}

/**
 * Tags a Bangla text string with parts of speech
 *
 * @param {string} text - The Bangla text to tag
 * @returns {TaggedWord[]} Array of words with their POS tags and features
 *
 * @description
 * This function first tokenizes the input text into words and then
 * performs POS tagging on the resulting word sequence.
 *
 * @example
 * ```typescript
 * const text = "আমি বাংলায় গান গাই";
 * const tagged = tagText(text);
 * console.log(tagged);
 * // Output: [
 * //   { word: "আমি", tag: UniversalPOSTag.PRON },
 * //   { word: "বাংলায়", tag: UniversalPOSTag.ADP },
 * //   { word: "গান", tag: UniversalPOSTag.NOUN },
 * //   { word: "গাই", tag: UniversalPOSTag.VERB }
 * // ]
 * ```
 */
export function tagText(text: string): TaggedWord[] {
  // TODO: Implement actual POS tagging logic
  const words = text.split(/\s+/);
  return tagWords(words);
}

/**
 * Gets the most common POS tags in a sequence of tagged words
 *
 * @param {TaggedWord[]} taggedWords - Array of tagged words
 * @returns {Map<UniversalPOSTag, number>} Map of POS tags to their frequencies
 *
 * @description
 * This function analyzes a sequence of tagged words and returns
 * a map showing how many times each POS tag appears.
 *
 * @example
 * ```typescript
 * const tagged = [
 *   { word: "আমি", tag: UniversalPOSTag.PRON },
 *   { word: "বাংলায়", tag: UniversalPOSTag.ADP },
 *   { word: "গান", tag: UniversalPOSTag.NOUN },
 *   { word: "গাই", tag: UniversalPOSTag.VERB }
 * ];
 * const frequencies = getPOSTagFrequencies(tagged);
 * console.log(frequencies);
 * // Output: Map(4) {
 * //   UniversalPOSTag.PRON => 1,
 * //   UniversalPOSTag.ADP => 1,
 * //   UniversalPOSTag.NOUN => 1,
 * //   UniversalPOSTag.VERB => 1
 * // }
 * ```
 */
export function getPOSTagFrequencies(
  taggedWords: TaggedWord[],
): Map<UniversalPOSTag, number> {
  const frequencies = new Map<UniversalPOSTag, number>();

  for (const { tag } of taggedWords) {
    frequencies.set(tag, (frequencies.get(tag) || 0) + 1);
  }

  return frequencies;
}
