import { describe, expect, test } from "bun:test";

import {
  removePrefix,
  removeSuffix,
  stemWord,
  stemWords,
} from "../src/stemming";
import testData from "./stemming.data.json";

describe("Bangla Stemmer", () => {
  // Test removing prefixes
  describe("removePrefix", () => {
    test("should remove common prefixes", () => {
      testData.removePrefix.commonPrefixes.forEach(({ input, expected }) => {
        expect(removePrefix(input)).toBe(expected);
      });
    });

    test("should not remove prefix if word is too short", () => {
      testData.removePrefix.tooShort.forEach(({ input, expected }) => {
        expect(removePrefix(input)).toBe(expected);
      });
    });

    test("should not modify word if no prefix matches", () => {
      testData.removePrefix.noMatches.forEach(({ input, expected }) => {
        expect(removePrefix(input)).toBe(expected);
      });
    });
  });

  // Test removing suffixes
  describe("removeSuffix", () => {
    test("should remove common suffixes", () => {
      testData.removeSuffix.commonSuffixes.forEach(({ input, expected }) => {
        expect(removeSuffix(input)).toBe(expected);
      });
    });

    test("should not remove suffix if word is too short", () => {
      testData.removeSuffix.tooShort.forEach(({ input, expected }) => {
        expect(removeSuffix(input)).toBe(expected);
      });
    });

    test("should not modify word if no suffix matches", () => {
      testData.removeSuffix.noMatches.forEach(({ input, expected }) => {
        expect(removeSuffix(input)).toBe(expected);
      });
    });
  });

  // Test stemWord function
  describe("stemWord", () => {
    test("should stem words by removing prefixes and suffixes", () => {
      testData.stemWord.removeAffixes.forEach(({ input, expected }) => {
        expect(stemWord(input)).toBe(expected);
      });
    });

    test("should handle words with both prefixes and suffixes", () => {
      testData.stemWord.bothPrefixAndSuffix.forEach(({ input, expected }) => {
        expect(stemWord(input)).toBe(expected);
      });
    });

    test("should not modify words without known prefixes or suffixes", () => {
      testData.stemWord.noModifications.forEach(({ input, expected }) => {
        expect(stemWord(input)).toBe(expected);
      });
    });
  });

  // Test stemWords function
  describe("stemWords", () => {
    test("should stem an array of words", () => {
      const { input, expected } = testData.stemWords.multipleWords;
      expect(stemWords(input)).toEqual(expected);
    });

    test("should handle empty arrays", () => {
      const { input, expected } = testData.stemWords.emptyArray;
      expect(stemWords(input)).toEqual(expected);
    });

    test("should handle mixed words with and without affixes", () => {
      const { input, expected } = testData.stemWords.mixedWords;
      expect(stemWords(input)).toEqual(expected);
    });
  });
});
