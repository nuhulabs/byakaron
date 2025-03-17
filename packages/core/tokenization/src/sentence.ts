import { SENTENCE_SEPARATORS_REGEX } from "./constant";

/**
 * Tokenizes a Bangla text into an array of sentences.
 * 
 * @param text - The input Bangla text to tokenize
 * @returns A Set of cleaned and tokenized sentences
 * 
 * @description
 * This function performs the following steps:
 * 1. Splits text by line breaks
 * 2. Further splits by Bangla sentence separators
 * 3. Cleans each sentence
 * 4. Filters sentences based on the following criteria:
 *    - Must contain Bangla characters
 *    - Must have more than 3 words
 *    - Must not be empty
 * 5. Returns a Set to remove duplicates
 * 
 * @example
 * ```typescript
 * const text: string = "আমি বাংলায় গান গাই। তুমি কি শুনবে?";
 * const sentences: Set<string> = tokenizeToSentences(text);
 * console.log(Array.from(sentences));
 * // Output: ["আমি বাংলায় গান গাই", "তুমি কি শুনবে"]
 * ```
 */
export function tokenizeToSentences(text: string) {
  // Split by line break
  const splittedSentences = text
    .split("\n")
    .flatMap((sentence) =>
      sentence.split(SENTENCE_SEPARATORS_REGEX).filter(Boolean)
    );

  // Cleanup each sentence
  return new Set(
    splittedSentences
      .map(cleanup)
      .filter((sentence) => /[\u0980-\u09FF]/.test(sentence))
      .filter((sentence) => sentence.split(" ").length > 3)
      .filter(Boolean)
  );
}

/**
 * Cleans a Bangla sentence by removing unwanted content and normalizing the text.
 * 
 * @param text - The input sentence to clean
 * @returns A cleaned sentence string containing only valid Bangla content
 * 
 * @description
 * This function performs comprehensive cleaning:
 * 1. Removes text inside various brackets: (), [], {}, <>
 * 2. Removes URLs and email addresses
 * 3. Removes HTML entities
 * 4. Removes Latin characters
 * 5. Keeps only Bangla characters, spaces, and essential punctuation
 * 6. Normalizes whitespace and punctuation:
 *    - Replaces multiple spaces with single space
 *    - Removes spaces before punctuation
 *    - Removes consecutive periods
 *    - Removes consecutive newlines
 *    - Removes trailing hyphens and underscores
 *    - Removes complex patterns of punctuation at start/end
 * 7. Trims whitespace
 * 
 * @example
 * ```typescript
 * const text: string = "আমি (বাংলায়) গান গাই। https://example.com";
 * const cleaned: string = cleanup(text);
 * console.log(cleaned);
 * // Output: "আমি গান গাই"
 * ```
 */
function cleanup(text: string): string {
  return (
    text
      // Remove text inside () along with the braces
      .replace(/\([^)]*\)/g, "")
      // Remove text inside [] along with the braces
      .replace(/\[.*?\]/g, "")
      // Remove text inside {} along with the braces
      .replace(/\{.*?\}/g, "")
      // Remove text inside <> along with the braces
      .replace(/<.*?>/g, "")
      // Remove URLs
      .replace(/https?:\/\/\S+/g, "")
      // Remove email addresses
      .replace(/\S+@\S+\.\S+/g, "")
      // Remove HTML entities (like &nbsp;, &#39;, etc.)
      .replace(/&[a-zA-Z0-9#]+;/g, "")
      // Remove Latin characters (a-z, A-Z)
      .replace(/[a-zA-Z]/g, "")
      // Keep only Bangla characters (Unicode range: \u0980-\u09FF),
      // spaces, and essential punctuation
      .replace(/[^\u0980-\u09FF\s।,.?!:-]/g, "")
      // Replace multiple consecutive spaces with a single space
      .replace(/\s+/g, " ")
      // Remove spaces before punctuation
      .replace(/\s([।,.?!:])/g, "$1")
      // Remove consecutive periods
      .replace(/\.+/g, ".")
      // Remove consecutive newlines
      .replace(/\n+/g, "\n")
      // Remove consecutive spaces
      .replace(/\s+/g, " ")
      // Remove consecutive -
      .replace(/\-+/g, "-")
      // Remove trailing - and _
      .replace(/[-_]$/g, "")
      // Remove complex patterns of punctuation and symbols at the beginning of sentences
      .replace(/^[-.:,।?!_\s]+/g, "")
      // Remove complex patterns of punctuation and symbols at the end of sentences
      .replace(/[-.:,।?!_\s]+$/g, "")
      // Trim whitespace from beginning and end
      .trim()
  );
}
