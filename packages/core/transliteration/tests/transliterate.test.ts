import { describe, expect, test } from "bun:test";

import { transliterate } from "../src/transliterate";
import testData from "./transliterate.test.json";

const avro = testData.avro;
const ligature = testData.ligature;
const firstAvro = avro[0]!;

describe("transliterate", () => {
  avro.forEach(({ orva, avroed }, index) => {
    test(`mode: avro test ${index + 1}: ${orva.slice(0, 6)}..`, () => {
      expect(transliterate(orva, { mode: "avro" })).toEqual(avroed);
    });
  });

  Object.entries(ligature).forEach(([key, value]) => {
    test(`mode: avro ligature - ${key} > ${value}`, () => {
      expect(transliterate(key, { mode: "avro" })).toEqual(value);
    });
  });

  test("performance test - should handle large text quickly", () => {
    const ALLOWED_TIME_PER_THOUSAND_CHARS = process.arch === "arm64" ? 5 : 10; // Faster on ARM processors
    const sampleText = firstAvro.orva;
    const largeText = sampleText.repeat(100);

    const startTime = performance.now();
    const result = transliterate(largeText, { mode: "avro" });
    const endTime = performance.now();

    const executionTime = endTime - startTime;
    const executionTimePerThousandChars =
      (executionTime / largeText.length) * 1000;

    // The function should process large text in reasonable time (e.g., under 100ms)
    expect(executionTimePerThousandChars).toBeLessThan(
      ALLOWED_TIME_PER_THOUSAND_CHARS,
    );

    console.log(
      `Time Taken per 1000 chars: ${(executionTime / largeText.length) * 1000}ms`,
    );

    // Verify the result is correct (check first few characters)
    expect(result.slice(0, firstAvro.avroed.length)).toEqual(firstAvro.avroed);
  });
});
