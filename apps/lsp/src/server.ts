/**
 * Bangla Language Spellcheck HTTP Server
 * Exposes spellchecker functionality via HTTP endpoints
 */

import { BengaliSpellchecker, type SpellingError } from "@bntk/lsp";
import { prisma } from "@bntk/db";

// Define the database-backed spellchecker class
class BengaliSpellcheckerDbtaized extends BengaliSpellchecker {
  public async checkWord(word: string): Promise<boolean> {
    const wordRes = await prisma.words.findUnique({
      where: {
        text: word,
      },
    });

    return wordRes ? true : false;
  }
}

// Initialize the spellchecker
let spellchecker: BengaliSpellchecker;

// Initialize the database connection
try {
  // Initialize the spellchecker with dictionary from the database
  spellchecker = new BengaliSpellcheckerDbtaized();
  console.log("Initialized spellchecker with database connection");
} catch (error) {
  console.error("Failed to initialize database:", error);
  // Initialize with empty dictionary if database connection fails
  spellchecker = new BengaliSpellchecker();
  console.log("Initialized spellchecker without database connection");
}

interface SpellcheckRequest {
  text: string;
}

interface SpellcheckResponse {
  errors: {
    word: string;
    start: number;
    end: number;
    suggestions: string[];
  }[];
}

interface WordCheckRequest {
  word: string;
}

interface WordCheckResponse {
  isCorrect: boolean;
  suggestions?: string[];
}

// Helper function to check text for spelling errors
async function checkText(text: string): Promise<SpellingError[]> {
  // This is a simplified implementation - in a real scenario, you would
  // create a TextDocument and use the checkDocument method
  const errors: SpellingError[] = [];
  const words = text.split(/\s+/);
  let position = 0;

  for (const word of words) {
    const isCorrect = await spellchecker.checkWord(word);
    if (!isCorrect) {
      const suggestions = await spellchecker.getSuggestions(word);
      errors.push({
        word,
        start: position,
        end: position + word.length,
        suggestions,
      });
    }
    // Move position past this word and the following space
    position += word.length + 1;
  }

  return errors;
}

// Create a Bun HTTP server
export const createServer = ({ port }: { port: number }) => {
  console.log(
    `Bangla Language Spellcheck HTTP Server is running at http://localhost:${port}`
  );

  const server = Bun.serve({
    port,
    async fetch(req) {
      const url = new URL(req.url);

      // Enable CORS
      const headers = new Headers({
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
        "Content-Type": "application/json",
      });

      // Handle preflight requests
      if (req.method === "OPTIONS") {
        return new Response(null, { headers });
      }

      // Health check endpoint
      if (url.pathname === "/health") {
        return new Response(JSON.stringify({ status: "ok" }), {
          headers,
        });
      }

      // Spellcheck endpoint
      if (url.pathname === "/api/spellcheck" && req.method === "POST") {
        try {
          const body = (await req.json()) as SpellcheckRequest;

          if (!body.text) {
            return new Response(JSON.stringify({ error: "Text is required" }), {
              status: 400,
              headers,
            });
          }

          // Check the text for spelling errors
          const errors = await checkText(body.text);

          const response: SpellcheckResponse = {
            errors: errors.map((error) => ({
              word: error.word,
              start: error.start,
              end: error.end,
              suggestions: error.suggestions,
            })),
          };

          return new Response(JSON.stringify(response), { headers });
        } catch (error: unknown) {
          console.error("Error processing spellcheck request:", error);
          return new Response(
            JSON.stringify({ error: "Failed to process request" }),
            { status: 500, headers }
          );
        }
      }

      // Word check endpoint
      if (url.pathname === "/api/check-word" && req.method === "POST") {
        try {
          const body = (await req.json()) as WordCheckRequest;

          if (!body.word) {
            return new Response(JSON.stringify({ error: "Word is required" }), {
              status: 400,
              headers,
            });
          }

          const isCorrect = await spellchecker.checkWord(body.word);
          const response: WordCheckResponse = { isCorrect };

          if (!isCorrect) {
            // Get suggestions if the word is incorrect
            const suggestions = await spellchecker.getSuggestions(body.word);
            response.suggestions = suggestions;
          }

          return new Response(JSON.stringify(response), { headers });
        } catch (error: unknown) {
          console.error("Error processing word check request:", error);
          return new Response(
            JSON.stringify({ error: "Failed to process request" }),
            { status: 500, headers }
          );
        }
      }

      // Dictionary stats endpoint
      if (url.pathname === "/api/dictionary/stats" && req.method === "GET") {
        try {
          const count = await prisma.words.count();
          return new Response(JSON.stringify({ totalWords: count }), {
            headers,
          });
        } catch (error: unknown) {
          console.error("Error fetching dictionary stats:", error);
          return new Response(
            JSON.stringify({ error: "Failed to fetch dictionary stats" }),
            { status: 500, headers }
          );
        }
      }

      // Not found for any other routes
      return new Response(JSON.stringify({ error: "Not found" }), {
        status: 404,
        headers,
      });
    },
  });

  return server;
};

// Only start server if this is the main module
if (import.meta.main) {
  const port = process.env.PORT ? +process.env.PORT : 3001;
  const server = createServer({
    port,
  });
  console.log(`Server started on port ${port}`);
}
