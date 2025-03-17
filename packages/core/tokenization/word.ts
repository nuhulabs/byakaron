/**
 * Tokenize a sentence into words
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

function cleanup(word: string): string {
  return (
    word
      // Remove non-Bengali characters
      .replace(/[^\u0980-\u09FF\s\-\:\,\।\'\"\;\?\!]/g, "")
      // Remove digits from start and end
      .replace(/^[\u09E6-\u09EF]+|[\u09E6-\u09EF]+$/g, "")
      .trim()
  );
}