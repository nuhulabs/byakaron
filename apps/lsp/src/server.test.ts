/**
 * Tests for the Bangla Language Spellcheck HTTP Server
 */

import { describe, expect, test, beforeAll, afterAll, mock } from "bun:test";
import { BengaliSpellchecker } from "@bntk/lsp";
import { createServer } from "./server";

// Mock port for testing
const TEST_PORT = 3002;
const BASE_URL = `http://localhost:${TEST_PORT}`;

// Mock the BengaliSpellchecker class
mock.module("@bntk/lsp", () => {
  return {
    BengaliSpellchecker: class MockBengaliSpellchecker {
      async checkWord(word: string): Promise<boolean> {
        // Mock implementation: consider "ভালো" as correct, everything else as incorrect
        return word === "ভালো";
      }

      async getSuggestions(word: string): Promise<string[]> {
        // Mock implementation: return some suggestions for incorrect words
        if (word === "ভাল") {
          return ["ভালো", "ভাল্লাগে"];
        }
        return ["ভালো"];
      }
    },
    SpellingError: class {},
  };
});

// Mock the prisma client
mock.module("@bntk/db", () => {
  return {
    prisma: {
      words: {
        findUnique: async ({ where }: { where: { text: string } }) => {
          // Mock implementation: consider "ভালো" as in the dictionary
          return where.text === "ভালো" ? { text: where.text } : null;
        },
        count: async () => 1, // Mock implementation: return 1 word in the dictionary
      },
    },
  };
});

describe("Bangla Language Spellcheck HTTP Server", () => {
  let testServer: ReturnType<typeof Bun.serve>;

  // Start the server before all tests
  beforeAll(() => {
    // Import the server module again to use the test port
    testServer = createServer({
      port: TEST_PORT,
    });
  });

  // Stop the server after all tests
  afterAll(() => {
    testServer.stop();
  });

  test("Health check endpoint returns OK", async () => {
    const response = await fetch(`${BASE_URL}/health`);
    expect(response.status).toBe(200);

    const data = await response.json();
    expect(data).toEqual({ status: "ok" });
  });

  // test.skip("Spellcheck endpoint detects errors and provides suggestions", async () => {
  //   const response = await fetch(`${BASE_URL}/api/spellcheck`, {
  //     method: "POST",
  //     headers: {
  //       "Content-Type": "application/json",
  //     },
  //     body: JSON.stringify({
  //       text: "আমি ভাল আছি",
  //     }),
  //   });

  //   expect(response.status).toBe(200);

  //   const data = await response.json();
  //   expect(data).toHaveProperty("errors");
  //   expect(Array.isArray(data.errors)).toBe(true);

  //   // "ভাল" should be detected as an error
  //   const errors = data.errors;
  //   expect(errors.length).toBeGreaterThan(0);

  //   const errorWord = errors.find((e: any) => e.word === "ভাল");
  //   expect(errorWord).toBeDefined();
  //   expect(errorWord.suggestions).toContain("ভালো");
  // });

  test("Word check endpoint correctly identifies correct words", async () => {
    const response = await fetch(`${BASE_URL}/api/check-word`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        word: "ভালো",
      }),
    });

    expect(response.status).toBe(200);

    const data = await response.json();
    expect(data).toHaveProperty("isCorrect", true);
    expect(data).not.toHaveProperty("suggestions");
  });

  // test.skip("Word check endpoint correctly identifies incorrect words and provides suggestions", async () => {
  //   const response = await fetch(`${BASE_URL}/api/check-word`, {
  //     method: "POST",
  //     headers: {
  //       "Content-Type": "application/json",
  //     },
  //     body: JSON.stringify({
  //       word: "ভাল",
  //     }),
  //   });

  //   expect(response.status).toBe(200);

  //   const data = await response.json();
  //   expect(data).toHaveProperty("isCorrect", false);
  //   expect(data).toHaveProperty("suggestions");
  //   expect(data.suggestions).toContain("ভালো");
  // });

  test("Dictionary stats endpoint returns word count", async () => {
    const response = await fetch(`${BASE_URL}/api/dictionary/stats`);
    expect(response.status).toBe(200);

    const data = await response.json();
    expect(data).toHaveProperty("totalWords", 1);
  });

  test("Returns 400 for spellcheck with missing text", async () => {
    const response = await fetch(`${BASE_URL}/api/spellcheck`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    });

    expect(response.status).toBe(400);

    const data = await response.json();
    expect(data).toHaveProperty("error", "Text is required");
  });

  test("Returns 400 for word check with missing word", async () => {
    const response = await fetch(`${BASE_URL}/api/check-word`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    });

    expect(response.status).toBe(400);

    const data = await response.json();
    expect(data).toHaveProperty("error", "Word is required");
  });

  test("Returns 404 for unknown endpoints", async () => {
    const response = await fetch(`${BASE_URL}/unknown-endpoint`);
    expect(response.status).toBe(404);

    const data = await response.json();
    expect(data).toHaveProperty("error", "Not found");
  });
});
