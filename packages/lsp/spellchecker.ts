/**
 * Bangla language spellchecker implementation
 */
import { TextDocument } from "vscode-languageserver-textdocument";

import type {
  BengaliSpellcheckOptions,
  SpellcheckerService,
  SpellingError,
} from "./types";
import {
  extractBengaliWords,
  levenshteinDistance,
  normalizeBengaliText,
} from "./utils";

/**
 * Implementation of the Bangla spellchecker service
 */
export class BengaliSpellchecker implements SpellcheckerService {
  private dictionary: Set<string> = new Set();
  private options: Required<BengaliSpellcheckOptions>;

  /**
   * Create a new Bangla spellchecker
   * @param options Configuration options
   */
  constructor(options: BengaliSpellcheckOptions = {}) {
    this.options = {
      customDictionary: options.customDictionary || [],
      maxSuggestions: options.maxSuggestions || 5,
      ignoreWordsWithNumbers: options.ignoreWordsWithNumbers || true,
      ignoreWordsInAllUpperCase: options.ignoreWordsInAllUpperCase || false,
    };

    // Initialize with custom dictionary words
    this.options.customDictionary.forEach((word) => {
      this.dictionary.add(normalizeBengaliText(word));
    });

    // In a real implementation, we would load a Bangla dictionary here
    // This is a placeholder for demonstration purposes
  }

  /**
   * Load a dictionary from a data source
   * @param words Array of Bangla words to add to the dictionary
   */
  public loadDictionary(words: string[]): void {
    words.forEach((word) => {
      this.dictionary.add(normalizeBengaliText(word));
    });
    console.log(`Loaded ${words.length} words into dictionary`);
  }

  /**
   * Check a document for spelling errors
   * @param document The text document to check
   * @returns Array of spelling errors found
   */
  public async checkDocument(document: TextDocument): Promise<SpellingError[]> {
    const words = extractBengaliWords(document);
    const errors: SpellingError[] = [];

    for (const { word, start, end } of words) {
      // Skip words that should be ignored based on options
      if (this.shouldIgnoreWord(word)) {
        continue;
      }

      const isCorrect = await this.checkWord(word);
      if (!isCorrect) {
        const suggestions = await this.getSuggestions(word);
        errors.push({
          word,
          start,
          end,
          suggestions,
        });
      }
    }

    return errors;
  }

  /**
   * Check if a word should be ignored based on the options
   * @param word The word to check
   * @returns Whether the word should be ignored
   */
  private shouldIgnoreWord(word: string): boolean {
    // Ignore words with numbers if the option is enabled
    if (this.options.ignoreWordsWithNumbers && /\d/.test(word)) {
      return true;
    }

    // Ignore words in all uppercase if the option is enabled
    // Note: This may not be applicable for Bangla, but included for completeness
    if (
      this.options.ignoreWordsInAllUpperCase &&
      word === word.toUpperCase() &&
      word !== word.toLowerCase()
    ) {
      return true;
    }

    return false;
  }

  /**
   * Check a single word for spelling errors
   * @param word The word to check
   * @returns Whether the word is correctly spelled
   */
  public async checkWord(word: string): Promise<boolean> {
    const normalizedWord = normalizeBengaliText(word);
    return this.dictionary.has(normalizedWord);
  }

  /**
   * Get suggestions for a misspelled word
   * @param word The misspelled word
   * @returns Array of suggested corrections
   */
  public async getSuggestions(word: string): Promise<string[]> {
    const normalizedWord = normalizeBengaliText(word);
    const suggestions: [string, number][] = [];

    // Calculate Levenshtein distance for each word in the dictionary
    for (const dictWord of this.dictionary) {
      const distance = levenshteinDistance(normalizedWord, dictWord);
      suggestions.push([dictWord, distance]);
    }

    // Sort by distance (closest first) and take the top N suggestions
    return suggestions
      .sort((a, b) => a[1] - b[1])
      .slice(0, this.options.maxSuggestions)
      .map(([suggestion]) => suggestion);
  }
}
