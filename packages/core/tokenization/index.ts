/**
 * Tokenize a paragraph into sentences
 */
export function tokenizeToSentences(text: string): string[] {
  return text.split("\n");
}

/**
 * Tokenize a sentence into words
 */
export function tokenizeToWords(text: string): string[] {
  const cleanedText = text.replace(/[^\u0980-\u09FF\s\-\:\,\।\'\"\;\?\!]/g, "");
  return cleanedText
    .split(/[\s\p{P}]+/u)
    .filter((word) => word.length > 0)
    .map((word) => {
      return (
        word
          // Remove digits
          .replace(/^[\u09E6-\u09EF]+|[\u09E6-\u09EF]+$/g, "")
          .trim()
      );
    })
    .filter(Boolean);
}
