/**
 * Tokenizes a Bangla text string into an array of words.
 * 
 * @param text - The input Bangla text to tokenize
 * @returns An array of cleaned and tokenized words
 * 
 * @description
 * This function performs the following steps:
 * 1. Cleans the input text by removing non-Bangla characters
 * 2. Splits the text by whitespace
 * 3. Further splits each segment by punctuation (excluding hyphens)
 * 4. Cleans each word by:
 *    - Removing trailing hyphens
 *    - Removing Bangla digits from start and end
 *    - Trimming whitespace
 * 5. Filters out empty strings
 * 
 * @example
 * ```typescript
 * const text: string = "আমি বাংলায় গান গাই";
 * const words: string[] = tokenizeToWords(text);
 * console.log(words);
 * // Output: ["আমি", "বাংলায়", "গান", "গাই"]
 * ```
 */
export function tokenizeToWords(text: string): string[] {
  // First clean up the entire text
  const cleanedText = cleanup(text);
  
  // Split by whitespace first
  return cleanedText
    .split(/\s+/)
    .flatMap(segment => {
      // For each segment, further split by punctuation and other separators
      // Note: We're excluding hyphen (-) from the split pattern
      const words = segment.split(/[,।;:'"?!]+/).filter(Boolean);
      
      return words.map(word => {
        // Remove trailing hyphens
        const cleanedWord = word.replace(/-+$/, "");
        // Remove digits from start and end
        return cleanedWord.replace(/^[\u09E6-\u09EF]+|[\u09E6-\u09EF]+$/g, "").trim();
      });
    })
    .filter(Boolean); // Remove empty strings
}

/**
 * Cleans a Bangla text string by removing unwanted characters and normalizing the text.
 * 
 * @param word - The input text to clean
 * @returns A cleaned text string containing only valid Bangla characters and essential punctuation
 * 
 * @description
 * This function:
 * 1. Removes all non-Bangla characters except:
 *    - Bangla Unicode range (\u0980-\u09FF)
 *    - Whitespace
 *    - Hyphen (-)
 *    - Essential punctuation (:, ।, ', ", ;, ?, !)
 * 2. Removes Bangla digits from start and end
 * 3. Trims whitespace
 * 
 * @example
 * ```typescript
 * const text: string = "আমি123বাংলায় গান গাই!";
 * const cleaned: string = cleanup(text);
 * console.log(cleaned);
 * // Output: "আমি বাংলায় গান গাই!"
 * ```
 */
function cleanup(word: string): string {
  return (
    word
      // Remove non-Bangla characters
      .replace(/[^\u0980-\u09FF\s\-\:\,\।\'\"\;\?\!]/g, "")
      // Remove digits from start and end
      .replace(/^[\u09E6-\u09EF]+|[\u09E6-\u09EF]+$/g, "")
      .trim()
  );
}