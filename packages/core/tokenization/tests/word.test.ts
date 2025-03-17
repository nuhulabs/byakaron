import { describe, test, expect } from "bun:test";
import { tokenizeToWords } from "../src/word";

describe("@bntk/tokenization", () => {
  describe("tokenizeToWords", () => {
    test("should remove prefix - from words", () => {
      const text = "-ইন্টাগ্রেটেড";
      const expected = ["ইন্টাগ্রেটেড"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should tokenize simple Bangla text", () => {
      const text = "আমি বাংলায় কথা বলি";
      const expected = ["আমি", "বাংলায়", "কথা", "বলি"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should handle empty string", () => {
      expect(tokenizeToWords("")).toEqual([]);
    });

    test("should handle whitespace-only string", () => {
      expect(tokenizeToWords("   ")).toEqual([]);
    });

    test("should split on word separators", () => {
      const text = "আমি, তুমি। সে; তারা:";
      const expected = ["আমি", "তুমি", "সে", "তারা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should handle punctuation marks", () => {
      const text = "আমি? তুমি! সে, তারা।";
      const expected = ["আমি", "তুমি", "সে", "তারা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should remove Bangla digits from start and end of words", () => {
      const text = "১২আমি৩৪ ৫৬বাংলা";
      const expected = ["আমি", "বাংলা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should keep Bangla digits in the middle of words", () => {
      const text = "আ১২মি বাং৩৪লা";
      const expected = ["আ১২মি", "বাং৩৪লা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should remove non-Bangla characters", () => {
      const text = "আমিabc বাংলাdef";
      const expected = ["আমি", "বাংলা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should handle mixed text with punctuation and digits", () => {
      const text = "১২আমি, ৩৪বাংলা! abc১২৩";
      const expected = ["আমি", "বাংলা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should handle quotes", () => {
      const text = "'আমি' \"বাংলা\"";
      const expected = ["আমি", "বাংলা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should handle hyphenated words", () => {
      const text = "আমি-তুমি বাংলা-ভাষা";
      const expected = ["আমি-তুমি", "বাংলা-ভাষা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should filter out empty words after processing", () => {
      const text = "আমি ১২৩ বাংলা";
      const expected = ["আমি", "বাংলা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should handle multiple consecutive separators", () => {
      const text = "আমি,,, বাংলা... কথা";
      const expected = ["আমি", "বাংলা", "কথা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should handle text with only non-Bangla characters", () => {
      const text = "abc 123 !@#";
      expect(tokenizeToWords(text)).toEqual([]);
    });

    test("should handle text with only Bangla digits", () => {
      const text = "১২৩ ৪৫৬ ৭৮৯";
      expect(tokenizeToWords(text)).toEqual([]);
    });
  });

  describe("word/cleanup", () => {
    test("should remove non-Bangla characters", () => {
      const text = "আমিabc123";
      const expected = ["আমি"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should preserve Bangla punctuation", () => {
      const text = "আমি, তুমি। সে: তারা-";
      const expected = ["আমি", "তুমি", "সে", "তারা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should handle text with mixed scripts", () => {
      const text = "আমি speak বাংলা";
      const expected = ["আমি", "বাংলা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });

    test("should trim whitespace", () => {
      const text = "  আমি  বাংলা  ";
      const expected = ["আমি", "বাংলা"];
      expect(tokenizeToWords(text)).toEqual(expected);
    });
  });
});
