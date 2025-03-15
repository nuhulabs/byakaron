/**
 * Remove unwanted word sequences and characters from Bengali sentences
 * - Removes text inside brackets: (), [], {}, <>
 * - Removes non-Bengali characters except essential punctuation and spaces
 * - Normalizes whitespace and removes extra spaces
 * - Handles special cases like URLs, email addresses, and numbers
 */
function cleanupSentence(text: string): string {
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
      // Trim whitespace from beginning and end
      .trim()
  );
}

/**
 * Split text into sentences by Bengalic KAR delimeter or new line
 */
export function cleanupSentences(text: string): string[] {
    // Split by line break
    const sentences = text.split("\n");

    // Split by KAR delimeter
    const karSentences = sentences.flatMap(sentence => sentence.split("।")).filter(Boolean);

    // Only keep sentences that are longer than 2 words
    const filteredSentences = karSentences.filter(sentence => sentence.split(" ").length > 2);

    // Cleanup each sentence
    return filteredSentences.map(cleanupSentence).filter(Boolean);
  }