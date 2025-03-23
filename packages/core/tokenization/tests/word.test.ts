import { describe, expect, test } from "bun:test";

import { tokenizeToWords } from "../src/word";
import testData from "./word.data.json";

describe("@bntk/tokenization", () => {
  describe("tokenizeToWords", () => {
    // Use data-driven testing approach
    testData.forEach((testGroup) => {
      test(testGroup.name, () => {
        testGroup.cases.forEach((testCase) => {
          expect(tokenizeToWords(testCase.input)).toEqual(testCase.expected);
        });
      });
    });
  });
});
