import * as rules from "../assets/rules.json";

/**
 * Phonetic rules for Bangla transliteration
 */
export const phonetic = {
  /**
   * Normalizes the input string to handle case sensitivity correctly
   * according to the predefined rules.
   *
   * @param {string} input - The input string to fix
   * @returns {string} The fixed string with appropriate case handling
   */
  fixString(input: string) {
    let fixed = "";
    for (let i = 0; i < input.length; ++i) {
      const cChar = input.charAt(i);
      if (this.isCaseSensitive(cChar)) {
        fixed += cChar;
      } else {
        fixed += cChar.toLowerCase();
      }
    }
    return fixed;
  },
  /**
   * Checks if a character is a vowel according to phonetic rules.
   *
   * @param {string} c - The character to check
   * @returns {boolean} True if the character is a vowel, false otherwise
   */
  isVowel(c: string) {
    return rules.vowel.includes(c.toLowerCase());
  },
  /**
   * Checks if a character is a consonant according to phonetic rules.
   *
   * @param {string} c - The character to check
   * @returns {boolean} True if the character is a consonant, false otherwise
   */
  isConsonant(c: string) {
    return rules.consonant.includes(c.toLowerCase());
  },
  /**
   * Checks if a character is a punctuation (not a vowel or consonant).
   *
   * @param {string} c - The character to check
   * @returns {boolean} True if the character is punctuation, false otherwise
   */
  isPunctuation(c: string) {
    return !(this.isVowel(c) || this.isConsonant(c));
  },
  /**
   * Checks if a substring exactly matches a target string at a specific position.
   *
   * @param {string} needle - The substring to search for
   * @param {string} heystack - The string to search in
   * @param {number} start - The start position for the comparison
   * @param {number} end - The end position for the comparison
   * @param {boolean} not - Whether to negate the result
   * @returns {boolean} True if the substring is found at the specified position
   */
  isExact(
    needle: string,
    heystack: string,
    start: number,
    end: number,
    not: boolean,
  ) {
    return (
      (start >= 0 &&
        end < heystack.length &&
        heystack.substring(start, end) === needle) !== not
    );
  },
  /**
   * Checks if a character is case-sensitive according to phonetic rules.
   *
   * @param {string} c - The character to check
   * @returns {boolean} True if the character is case-sensitive, false otherwise
   */
  isCaseSensitive(c: string) {
    return rules.casesensitive.includes(c.toLowerCase());
  },
};
