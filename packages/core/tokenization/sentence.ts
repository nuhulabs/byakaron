import { SENTENCE_SEPARATORS_REGEX } from "./constant";

/**
 * Split text into sentences by Bengalic KAR delimeter, new line, or multiple punctuation patterns
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
 * Remove unwanted word sequences and characters from Bengali sentences
 * - Removes text inside brackets: (), [], {}, <>
 * - Removes non-Bengali characters except essential punctuation and spaces
 * - Normalizes whitespace and removes extra spaces
 * - Handles special cases like URLs, email addresses, and numbers
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
      // Keep only Bengali characters (Unicode range: \u0980-\u09FF),
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
