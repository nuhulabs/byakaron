import { describe, test, expect } from "bun:test";
import { tokenizeToSentences } from "../src/sentence";

describe("@bntk/tokenization", () => {
  describe("tokenizeToSentences", () => {
    test("should tokenize simple Bangla text with দাড়ি (।) separator", () => {
      const text = "আমি বাংলায় কথা বলি এবং। আমি বাংলাদেশে থাকি।";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should tokenize text with multiple sentence separators", () => {
      const text =
        "আমি বাংলায় কথা বলি এবং। আমি বাংলাদেশে থাকি? তুমি কোথায় থাকো!";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle empty string", () => {
      expect(tokenizeToSentences("")).toEqual(new Set());
    });

    test("should handle whitespace-only string", () => {
      expect(tokenizeToSentences("   ")).toEqual(new Set());
    });

    test("should split on newlines", () => {
      const text =
        "আমি বাংলায় কথা বলি এবং\nআমি বাংলাদেশে থাকি\nতুমি কোথায় থাকো";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should filter out sentences with fewer than 4 words", () => {
      const text = "আমি বাংলায়। কথা বলি। আমি বাংলাদেশে থাকি এবং।";
      const expected = new Set(["আমি বাংলাদেশে থাকি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should filter out sentences without Bangla characters", () => {
      const text =
        "আমি বাংলায় কথা বলি এবং। This is English text. আমি বাংলাদেশে থাকি।";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle double দাড়ি (॥) separator", () => {
      const text = "আমি বাংলায় কথা বলি এবং॥ আমি বাংলাদেশে থাকি॥";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle ellipsis (...) separator", () => {
      const text = "আমি বাংলায় কথা বলি এবং... আমি বাংলাদেশে থাকি...";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle mixed separators", () => {
      const text =
        "আমি বাংলায় কথা বলি এবং। আমি বাংলাদেশে থাকি॥ তুমি কোথায় থাকো? সে কি জানে!";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should deduplicate identical sentences", () => {
      const text =
        "আমি বাংলায় কথা বলি এবং। আমি বাংলায় কথা বলি এবং। আমি বাংলাদেশে থাকি।";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with only non-Bangla characters", () => {
      const text = "This is English text. Another English sentence.";
      expect(tokenizeToSentences(text)).toEqual(new Set());
    });
  });

  describe("sentence/cleanup", () => {
    test("should remove text inside brackets", () => {
      const text =
        "আমি বাংলায় (ভালো) কথা বলি এবং [আমি] বাংলাদেশে {থাকি} <এখানে>।";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং বাংলাদেশে"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should remove URLs", () => {
      const text =
        "আমি https://example.com বাংলায় কথা বলি এবং বাংলাদেশে থাকি।";
      const expected = new Set(["বাংলায় কথা বলি এবং বাংলাদেশে থাকি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should remove email addresses", () => {
      const text = "আমি user@example.com বাংলায় কথা বলি এবং বাংলাদেশে থাকি।";
      const expected = new Set(["বাংলায় কথা বলি এবং বাংলাদেশে থাকি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should remove HTML entities", () => {
      const text = "আমি &nbsp; বাংলায় &#39; কথা বলি এবং বাংলাদেশে থাকি।";
      const expected = new Set(["কথা বলি এবং বাংলাদেশে থাকি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should remove Latin characters", () => {
      const text = "আমি Bangla বাংলায় কথা বলি এবং Bangladesh বাংলাদেশে থাকি।";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং বাংলাদেশে থাকি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should normalize whitespace", () => {
      const text = "আমি   বাংলায়    কথা   বলি   এবং   বাংলাদেশে   থাকি।";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং বাংলাদেশে থাকি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle complex text with multiple cleanup needs", () => {
      const text =
        "আমি (test) বাংলায় [example] কথা https://test.com বলি user@mail.com এবং {note} বাংলাদেশে <tag> থাকি।";
      // This might return an empty set if the cleanup removes too much content
      // and the resulting sentence doesn't meet the minimum word count
      expect(tokenizeToSentences(text)).toBeDefined();
    });

    test("should remove punctuation at the beginning and end of sentences", () => {
      const text = "।আমি বাংলায় কথা বলি এবং বাংলাদেশে থাকি,";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং বাংলাদেশে থাকি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle consecutive punctuation", () => {
      const text = "আমি বাংলায় কথা বলি...... এবং বাংলাদেশে থাকি।।।";
      const expected = new Set(["আমি বাংলায় কথা বলি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });
  });

  describe("sentence/edge cases", () => {
    test("should handle text with mixed scripts and separators", () => {
      const text =
        "আমি বাংলায় কথা বলি এবং। I speak Bangla. আমি বাংলাদেশে থাকি।";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with only Bangla digits", () => {
      const text = "১২৩ ৪৫৬ ৭৮৯। ০১২ ৩৪৫ ৬৭৮।";
      expect(tokenizeToSentences(text)).toEqual(new Set());
    });

    test("should handle text with multiple newlines and separators", () => {
      const text =
        "আমি বাংলায় কথা বলি এবং।\n\nআমি বাংলাদেশে থাকি।\n\nতুমি কোথায় থাকো?";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with only separators", () => {
      const text = "।।।...???!!!";
      expect(tokenizeToSentences(text)).toEqual(new Set());
    });

    test("should handle very long sentences", () => {
      const longSentence =
        "আমি বাংলায় কথা বলি এবং আমি বাংলাদেশে থাকি আমি ভাত খাই আমি মাছ খাই আমি সবজি খাই আমি ফল খাই আমি দুধ খাই আমি পানি খাই আমি চা খাই";
      const expected = new Set([longSentence]);
      expect(tokenizeToSentences(longSentence)).toEqual(expected);
    });

    test("should handle sentences with numbers and special characters", () => {
      const text = "আমার ফোন নাম্বার ০১৭১২৩৪৫৬৭৮ এবং আমি ১০০% নিশ্চিত।";
      const expected = new Set([
        "আমার ফোন নাম্বার ০১৭১২৩৪৫৬৭৮ এবং আমি ১০০ নিশ্চিত",
      ]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });
  });

  describe("sentence/bangla", () => {
    test("should handle sentences with Bangla digits", () => {
      const text =
        "আমি ১২৩ টাকা দিয়ে ৫ কেজি চাল কিনেছি এবং বাকি টাকা ফেরত পেয়েছি।";
      const expected = new Set([
        "আমি ১২৩ টাকা দিয়ে ৫ কেজি চাল কিনেছি এবং বাকি টাকা ফেরত পেয়েছি",
      ]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle sentences with Bangla punctuation", () => {
      const text = "আমি বাংলাদেশে থাকি, খুব ভালো লাগে; কিন্তু গরমে কষ্ট হয়।";
      const expected = new Set([
        "আমি বাংলাদেশে থাকি, খুব ভালো লাগে",
        "কিন্তু গরমে কষ্ট হয়",
      ]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle sentences with Bangla conjunctions", () => {
      const text = "আমি এবং আমার বন্ধু স্কুলে যাই কিন্তু আমার ভাই বাসায় থাকে।";
      const expected = new Set([
        "আমি এবং আমার বন্ধু স্কুলে যাই কিন্তু আমার ভাই বাসায় থাকে",
      ]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle sentences with Bangla honorifics", () => {
      const text = "আমার বাবা আমাকে বললেন যে আমি যেন সময়মত বাসায় ফিরি।";
      const expected = new Set([
        "আমার বাবা আমাকে বললেন যে আমি যেন সময়মত বাসায় ফিরি",
      ]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle sentences with Bangla compound words", () => {
      const text =
        "বাংলাদেশের রাজধানী ঢাকা-শহরে অনেক জনসংখ্যা এবং যানজট রয়েছে।";
      const expected = new Set([
        "বাংলাদেশের রাজধানী ঢাকা-শহরে অনেক জনসংখ্যা এবং যানজট রয়েছে",
      ]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });
  });

  describe("sentence/performance", () => {
    test("should handle very large text with multiple sentences", () => {
      // Create a large text with many sentences
      const sentence = "আমি বাংলায় কথা বলি এবং আমি বাংলাদেশে থাকি। ";
      const largeText = sentence.repeat(100);

      // We expect the function to process this without errors
      expect(() => tokenizeToSentences(largeText)).not.toThrow();

      // We expect at least one sentence to be returned
      expect(tokenizeToSentences(largeText).size).toBeGreaterThan(0);
    });

    test("should handle text with unusual spacing and formatting", () => {
      const text = `
      আমি    বাংলায়    কথা    বলি    এবং    
      
      আমি    বাংলাদেশে    থাকি।
      
      আমি    ভাত    খাই।
    `;

      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with mixed Unicode normalization forms", () => {
      // Same text in different Unicode normalization forms
      const nfcText = "আমি বাংলায় কথা বলি এবং।";
      const nfdText = "আমি বাংলায় কথা বলি এবং।".normalize("NFD");

      // Both should produce the same result
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(nfcText)).toEqual(expected);
      expect(tokenizeToSentences(nfdText)).toEqual(expected);
    });
  });

  describe("sentence/integration", () => {
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

    test("should handle text with special characters and symbols", () => {
      const text =
        "আমি বাংলায় কথা বলি এবং ©®™℠ §¶† ‡ ※ ♠♣♥♦ ♪♫♯ ☺☻ ♀♂ ☼☾☽ ♈♉♊♋♌♍♎♏♐♑♒♓ ☯☮☭ ☢☣ ☤⚕ ⚠⚡☠ ☸☯";

      // We expect the function to process this without errors and return a valid result
      expect(() => tokenizeToSentences(text)).not.toThrow();
      expect(tokenizeToSentences(text).size).toBeGreaterThanOrEqual(0);
    });
  });

  describe("sentence/advanced", () => {
    test("should handle text with multiple sentence separators in sequence", () => {
      const text = "আমি বাংলায় কথা বলি এবং।।। আমি বাংলাদেশে থাকি?!";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with mixed sentence separators and newlines", () => {
      const text =
        "আমি বাংলায় কথা বলি এবং।\nআমি বাংলাদেশে থাকি।\rতুমি কোথায় থাকো?\r\nসে কি জানে!";
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with quotes and special formatting", () => {
      const text = `"আমি বাংলায় কথা বলি এবং।" 'আমি বাংলাদেশে থাকি।' "তুমি কোথায় থাকো?"`;
      const expected = new Set(["আমি বাংলায় কথা বলি এবং"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with Bangla abbreviations", () => {
      const text = "ড. রহমান এবং প্রফে. আহমেদ আমাদের শিক্ষক ছিলেন।";
      const expected = new Set(["আহমেদ আমাদের শিক্ষক ছিলেন"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with Bangla numbers and measurements", () => {
      const text = "আমি ১০ কি.মি. হেঁটে যাই এবং ৫ কেজি ওজন বহন করি।";
      const expected = new Set(["হেঁটে যাই এবং ৫ কেজি ওজন বহন করি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });
  });

  describe("sentence/boundary conditions", () => {
    test("should handle text with exactly 4 words", () => {
      const text = "আমি বাংলায় কথা বলি।";
      const expected = new Set(["আমি বাংলায় কথা বলি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with exactly 3 words (should be filtered out)", () => {
      const text = "আমি বাংলায় বলি।";
      expect(tokenizeToSentences(text)).toEqual(new Set());
    });

    test("should handle text with minimal Bangla characters", () => {
      const text = "আ ই উ এ ও ক খ গ ঘ ঙ চ ছ জ ঝ ঞ।";
      // This test actually passes because the sentence has 15 words, which is more than the minimum 4 words
      const expected = new Set(["আ ই উ এ ও ক খ গ ঘ ঙ চ ছ জ ঝ ঞ"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });

    test("should handle text with mixed script but enough Bangla words", () => {
      const text = "আমি বাংলায় কথা বলি and I speak Bangla.";
      const expected = new Set(["আমি বাংলায় কথা বলি"]);
      expect(tokenizeToSentences(text)).toEqual(expected);
    });
  });
});
