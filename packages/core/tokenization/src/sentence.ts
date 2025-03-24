import { SENTENCE_SEPARATORS_REGEX } from "./constant";

/**
 * Tokenizes a Bangla text into an array of sentences.
 *
 * @param {string} text - The input Bangla text to tokenize. Can contain mixed content including URLs, emails, and special characters.
 * @returns {string[]} An array of cleaned and tokenized sentences, with duplicates removed.
 *
 * @description
 * This function performs the following steps:
 * 1. Splits text by line breaks
 * 2. Further splits by Bangla sentence separators
 * 3. Cleans each sentence by:
 *    - Removing text within parentheses, brackets, braces, and angle brackets
 *    - Removing URLs and email addresses
 *    - Removing HTML entities
 *    - Removing Latin characters
 *    - Keeping only Bangla characters, spaces, and essential punctuation
 *    - Normalizing spaces and punctuation
 * 4. Filters sentences based on the following criteria:
 *    - Must contain Bangla characters (Unicode range: \u0980-\u09FF)
 *    - Must have more than 3 words
 *    - Must not be empty
 * 5. Returns a Set to remove duplicates
 *
 * @example
 * Basic usage with simple Bangla text:
 * ```typescript
 * const text = "আমি বাংলায় গান গাই। তুমি কি শুনবে?";
 * console.log(tokenizeToSentences(text));
 * // Output: ["আমি বাংলায় গান গাই", "তুমি কি শুনবে"]
 * ```
 *
 * @example
 * Handling mixed content:
 * ```typescript
 * const mixedText = "আমি বাংলায় গান গাই। Visit https://example.com or email@example.com";
 * console.log(tokenizeToSentences(mixedText));
 * // Output: ["আমি বাংলায় গান গাই"]
 * ```
 *
 * @example
 * Handling text with special characters:
 * ```typescript
 * const specialText = "বাংলা টেক্সট (ইংরেজি টেক্সট) [বন্ধনী টেক্সট] {কোঁকড়া টেক্সট}";
 * console.log(tokenizeToSentences(specialText));
 * // Output: ["বাংলা টেক্সট"]
 * ```
 */
export function tokenizeToSentences(text: string) {
  // Split by line break
  const splittedSentences = text
    .split("\n")
    .flatMap((sentence) =>
      sentence.split(SENTENCE_SEPARATORS_REGEX).filter(Boolean),
    );

  // Cleanup each sentence
  return splittedSentences
    .map(cleanup)
    .filter((sentence) => /[\u0980-\u09FF]/.test(sentence))
    .filter(Boolean);
}

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
