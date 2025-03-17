/**
 * Utility functions for the Bangla spellcheck LSP
 */

import { TextDocument } from 'vscode-languageserver-textdocument';

/**
 * Extract Bangla words from a text document
 * @param document The text document to extract words from
 * @returns Array of words with their positions
 */
export function extractBengaliWords(document: TextDocument): { word: string; start: number; end: number }[] {
  const text = document.getText();
  const words: { word: string; start: number; end: number }[] = [];
  
  // Bangla Unicode range: \u0980-\u09FF
  // This regex matches Bangla words
  const bengaliWordRegex = /[\u0980-\u09FF]+/g;
  let match: RegExpExecArray | null;
  
  while ((match = bengaliWordRegex.exec(text)) !== null) {
    words.push({
      word: match[0],
      start: match.index,
      end: match.index + match[0].length
    });
  }
  
  return words;
}

/**
 * Calculate Levenshtein distance between two strings
 * Used for suggesting corrections for misspelled words
 * @param a First string
 * @param b Second string
 * @returns The edit distance between the strings
 */
export function levenshteinDistance(a: string, b: string): number {
  const matrix: number[][] = [];

  // Initialize the matrix
  for (let i = 0; i <= b.length; i++) {
    matrix[i] = [i];
  }
  
  for (let j = 0; j <= a.length; j++) {
    matrix[0][j] = j;
  }

  // Fill the matrix
  for (let i = 1; i <= b.length; i++) {
    for (let j = 1; j <= a.length; j++) {
      const cost = a[j - 1] === b[i - 1] ? 0 : 1;
      matrix[i][j] = Math.min(
        matrix[i - 1][j] + 1,      // deletion
        matrix[i][j - 1] + 1,      // insertion
        matrix[i - 1][j - 1] + cost // substitution
      );
    }
  }

  return matrix[b.length][a.length];
}

/**
 * Normalize Bangla text to handle different forms of the same character
 * @param text The text to normalize
 * @returns Normalized text
 */
export function normalizeBengaliText(text: string): string {
  // Implement normalization rules for Bangla text
  // This is a placeholder - actual implementation would handle specific Bangla normalization rules
  return text;
} 