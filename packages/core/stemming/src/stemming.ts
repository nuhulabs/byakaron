import stemmingData from "../assets/stemming.json";

interface StemmingData {
  language: string;
  prefixes: Record<string, string>;
  suffixes: Record<string, string>;
  special_cases: Record<string, string>;
}

// Cast stemmingData to our interface
const typedStemmingData = stemmingData as StemmingData;

// Sort prefixes and suffixes by length (longest first to ensure longest match)
const sortedPrefixes = Object.keys(typedStemmingData.prefixes).sort(
  (a, b) => b.length - a.length,
);
const sortedSuffixes = Object.keys(typedStemmingData.suffixes).sort(
  (a, b) => b.length - a.length,
);

/**
 * Removes matching prefix from the beginning of a word
 * @param word The word to remove prefix from
 * @returns The word with prefix removed if matched, otherwise original word
 */
export function removePrefix(word: string): string {
  if (word.length <= 2) return word; // Don't stem very short words

  for (const prefix of sortedPrefixes) {
    if (word.startsWith(prefix) && word.length > prefix.length + 1) {
      // Get the replacement for this prefix (or empty string if no replacement)
      const replacement = typedStemmingData.prefixes[prefix] || "";
      // Apply the replacement
      return replacement + word.substring(prefix.length);
    }
  }

  return word;
}

/**
 * Removes matching suffix from the end of a word
 * @param word The word to remove suffix from
 * @returns The word with suffix removed if matched, otherwise original word
 */
export function removeSuffix(word: string): string {
  if (word.length <= 2) return word; // Don't stem very short words

  for (const suffix of sortedSuffixes) {
    if (word.endsWith(suffix) && word.length > suffix.length + 1) {
      // Get the replacement for this suffix (or empty string if no replacement)
      const replacement = typedStemmingData.suffixes[suffix] || "";
      return word.substring(0, word.length - suffix.length) + replacement;
    }
  }

  return word;
}

/**
 * Stems a Bangla word by removing prefixes and suffixes
 * @param word The word to stem
 * @returns The stemmed word
 */
export function stemWord(word: string): string {
  // Check for special cases first
  if (
    typedStemmingData.special_cases &&
    typedStemmingData.special_cases[word]
  ) {
    return typedStemmingData.special_cases[word];
  }

  let stemmed = removePrefix(word);
  stemmed = removeSuffix(stemmed);
  return stemmed;
}

/**
 * Stems an array of Bangla words
 * @param words Array of words to stem
 * @returns Array of stemmed words
 */
export function stemWords(words: string[]): string[] {
  return words.map((word) => stemWord(word));
}

// For backward compatibility with existing code
export default {
  stem: stemWord,
  stemWords,
  removePrefix,
  removeSuffix,
};
