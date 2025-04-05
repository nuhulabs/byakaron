import { describe, expect, test } from "bun:test";

import { transliterate } from "../src/transliterate";
import testData from "./transliterate.test.json";

const samples = testData.samples;
const ligature = testData.ligature;
const firstSample = samples[0]!;

describe("transliterate", () => {
  samples.forEach(({ en, bn }, index) => {
    test(`avro ${index + 1}: ${en.slice(0, 6)}..`, () => {
      const received = transliterate(en, { mode: "avro" });
      const expected = bn;
      // console.log({ received, expected });

      expect(received).toEqual(expected);
    });
  });

  Object.entries(ligature).forEach(([key, value]) => {
    test(`avro: ${key} ➜ ${value}`, () => {
      const received = transliterate(key, { mode: "avro" });
      const expected = value;
      expect(received).toEqual(expected);
    });
  });

  // samples.forEach(({ en, bn }, index) => {
  //   test(`orva ${index + 1}: ${bn.slice(0, 6)}..`, () => {
  //     const received = transliterate(bn, { mode: "orva" });
  //     const expected = en;
  //     expect(received).toEqual(expected);
  //   });
  // });

  // Object.entries(ligature).forEach(([key, value]) => {
  //   test(`orva: ${value} ➜ ${key}`, () => {
  //     expect(transliterate(value, { mode: "orva" })).toEqual(key);
  //   }, 15); // 1 second timeout
  // });

  test("performance test - should handle large text quickly", () => {
    const ALLOWED_TIME_PER_THOUSAND_CHARS = process.arch === "arm64" ? 5 : 10; // Faster on ARM processors
    const largeBanglishText = firstSample.en.repeat(100);

    const startTime = performance.now();
    const result = transliterate(largeBanglishText, { mode: "avro" });
    const endTime = performance.now();

    const executionTime = endTime - startTime;
    const executionTimePerThousandChars =
      (executionTime / largeBanglishText.length) * 1000;

    // The function should process large text in reasonable time (e.g., under 100ms)
    expect(executionTimePerThousandChars).toBeLessThan(
      ALLOWED_TIME_PER_THOUSAND_CHARS,
    );

    console.log(
      `Time Taken per 1000 chars: ${(executionTime / largeBanglishText.length) * 1000}ms`,
    );

    // Verify the result is correct (check first few characters)
    expect(result.slice(0, firstSample.bn.length)).toEqual(firstSample.bn);
  });

  // Debug Test
  test(`Debug Test`, () => {
    // ["প", "্", "র", "ত", "ি", "ষ", "্", "ঠ", "া", "ন"];
    expect(transliterate("প্রতিষ্ঠান", { mode: "orva" })).toEqual(
      "protiShThan",
    );

    expect(transliterate("প্র", { mode: "orva" })).toEqual("pro");
  });
});
