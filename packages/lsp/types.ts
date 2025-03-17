/**
 * Type definitions for the Bangla spellcheck LSP
 */

import { TextDocument } from 'vscode-languageserver-textdocument';

/**
 * Represents a spelling error found in the document
 */
export interface SpellingError {
  /** The word that has a spelling error */
  word: string;
  /** The start position of the error in the document */
  start: number;
  /** The end position of the error in the document */
  end: number;
  /** Suggested corrections for the misspelled word */
  suggestions: string[];
}

/**
 * Configuration options for the Bangla spellchecker
 */
export interface BengaliSpellcheckOptions {
  /** Custom dictionary words to ignore */
  customDictionary?: string[];
  /** Maximum number of suggestions to provide */
  maxSuggestions?: number;
  /** Whether to ignore words with numbers */
  ignoreWordsWithNumbers?: boolean;
  /** Whether to ignore words in all uppercase */
  ignoreWordsInAllUpperCase?: boolean;
}

/**
 * Interface for the spellchecker service
 */
export interface SpellcheckerService {
  /**
   * Check a document for spelling errors
   * @param document The text document to check
   * @returns Array of spelling errors found
   */
  checkDocument(document: TextDocument): Promise<SpellingError[]>;
  
  /**
   * Check a single word for spelling errors
   * @param word The word to check
   * @returns Whether the word is correctly spelled
   */
  checkWord(word: string): Promise<boolean>;
  
  /**
   * Get suggestions for a misspelled word
   * @param word The misspelled word
   * @returns Array of suggested corrections
   */
  getSuggestions(word: string): Promise<string[]>;
} 