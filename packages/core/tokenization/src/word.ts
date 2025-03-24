/**
 * Tokenizes a Bangla text string into an array of words.
 *
 * @param {string} text - The input Bangla text to tokenize. Can contain mixed content including punctuation and special characters.
 * @returns {string[]} An array of cleaned and tokenized words, with empty strings removed.
 *
 * @description
 * This function performs the following steps:
 * 1. Cleans the input text by:
 *    - Removing non-Bangla characters (keeping only Unicode range: \u0980-\u09FF)
 *    - Preserving essential punctuation marks (।, ,, ;, :, ', ", ?, !)
 *    - Preserving hyphens for compound words
 * 2. Splits the text by whitespace
 * 3. Further splits each segment by punctuation (excluding hyphens)
 * 4. Cleans each word by:
 *    - Removing trailing hyphens
 *    - Removing Bangla digits from start and end
 *    - Trimming whitespace
 * 5. Filters out empty strings
 *
 * @example
 * Basic usage with simple Bangla text:
 * ```typescript
 * const text = "আমি বাংলায় গান গাই";
 * const words = tokenizeToWords(text);
 * console.log(words);
 * // Output: ["আমি", "বাংলায়", "গান", "গাই"]
 * ```
 *
 * @example
 * Handling text with punctuation:
 * ```typescript
 * const text = "আমি, বাংলায় গান গাই। তুমি কি শুনবে?";
 * const words = tokenizeToWords(text);
 * console.log(words);
 * // Output: ["আমি", "বাংলায়", "গান", "গাই", "তুমি", "কি", "শুনবে"]
 * ```
 *
 * @example
 * Handling compound words with hyphens:
 * ```typescript
 * const text = "আমি-তুমি বাংলা-ভাষা শিখছি";
 * const words = tokenizeToWords(text);
 * console.log(words);
 * // Output: ["আমি-তুমি", "বাংলা-ভাষা", "শিখছি"]
 * ```
 *
 * @example
 * Handling text with Bangla digits:
 * ```typescript
 * const text = "১টি বই ২টি খাতা";
 * const words = tokenizeToWords(text);
 * console.log(words);
 * // Output: ["টি", "বই", "টি", "খাতা"]
 * ```
 */
export function tokenizeToWords(text: string): string[] {
  // Split by whitespace first
  return text
    .split(/\s+/)
    .flatMap((segment) => {
      // For each segment, further split by punctuation and other separators
      // Note: We're excluding hyphen (-) from the split pattern
      return segment
        .split(/[,।;:'"?!]+/)
        .map(cleanup)
        .filter(Boolean);
    })
    .filter(Boolean); // Remove empty strings
}

function cleanup(word: string): string {
  return (
    word
      .trim()
      // Remove non-Bangla characters
      .replace(/[^\u0980-\u09FF\s\-\:\,\।\'\"\;\?\!]/g, "")
      // Remove starting and ending hyphens
      .replace(/^-+|-+$/g, "")
      // Remove Bangla digits from start and end
      // .replace(/^[\u09E6-\u09EF]+|[\u09E6-\u09EF]+$/g, "")
      // Remove if the whole word is bangla digits
      .replace(/^[\u09E6-\u09EF]+$/g, "")
      .trim()
  );
}
