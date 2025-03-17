import { describe, test, expect } from "bun:test";
import { tokenizeToSentences } from "../src/sentence";
import testData from "./sentence.data.json";

describe("@bntk/tokenization", () => {
  describe("tokenizeToSentences", () => {
    // Use data-driven testing approach
    testData.forEach((testGroup) => {
      test(testGroup.name, () => {
        testGroup.cases.forEach((testCase) => {
          const result = tokenizeToSentences(testCase.input);
          const expectedSet = new Set(testCase.expected);
          expect(result).toEqual(expectedSet);
        });
      });
    });

    // Additional tests that might be hard to represent in the JSON format
    test("should handle very large text with multiple sentences", () => {
      // Create a large text with many sentences
      const sentence = "আমি বাংলায় কথা বলি এবং আমি বাংলাদেশে থাকি। ";
      const largeText = sentence.repeat(100);

      // We expect the function to process this without errors
      expect(() => tokenizeToSentences(largeText)).not.toThrow();

      // We expect at least one sentence to be returned
      expect(tokenizeToSentences(largeText).size).toBeGreaterThan(0);
    });

    test("should handle text with mixed content that needs extensive cleanup", () => {
      const text = `
      আমি (private) বাংলায় [confidential] কথা বলি এবং।
      
      I am speaking in Bangla and I live in Bangladesh.
      
      আমি user@example.com বাংলাদেশে <span>থাকি</span> এবং https://example.com দেখি।
      
      আমি &nbsp; &#39;বাংলায়&#39; কথা বলি।
    `;

      // We expect the function to process this without errors
      expect(() => tokenizeToSentences(text)).not.toThrow();
    });
  });
});
