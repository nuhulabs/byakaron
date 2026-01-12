import { query } from "@/app/lib/db";
import { NextRequest, NextResponse } from "next/server";

import { transliterate } from "@bntk/transliteration";

interface WordSuggestion {
  id: number;
  value: string;
  romanized: string;
  similarity: number;
  frequency?: number;
}

interface SpellCheckResult {
  word: string;
  isCorrect: boolean;
  suggestions: WordSuggestion[];
  romanized: string;
  isRareWord?: boolean;
}

interface WordCheckResult {
  word: string;
  exists: boolean;
  frequency: number;
  isRare: boolean;
}

// Minimum frequency threshold - words below this are considered "rare"
const MIN_WORD_FREQUENCY = 80;

/**
 * Ensure required PostgreSQL extensions are enabled
 */
async function ensureExtensions() {
  try {
    await query(`CREATE EXTENSION IF NOT EXISTS pg_trgm`);
    await query(`CREATE EXTENSION IF NOT EXISTS fuzzystrmatch`);
  } catch (error) {
    console.warn("Could not create extensions (may already exist):", error);
  }
}

/**
 * Bulk check if words exist in the database and get their frequencies
 * Uses materialized view for fast frequency lookups
 * Returns a map of word -> { exists, frequency, isRare }
 */
async function checkWordsBulk(
  words: string[],
): Promise<Map<string, WordCheckResult>> {
  if (words.length === 0) return new Map();

  const result = await query<{ value: string; frequency: string }>(
    `
    SELECT 
      w.value,
      COALESCE(wf.freq, 0)::text as frequency
    FROM words w
    LEFT JOIN word_frequency_mv wf ON w.id = wf.word_id
    WHERE w.value = ANY($1::text[])
    `,
    [words],
  );

  const resultMap = new Map<string, WordCheckResult>();

  // Initialize all words as not found
  for (const word of words) {
    resultMap.set(word, { word, exists: false, frequency: 0, isRare: false });
  }

  // Update with found words
  for (const row of result) {
    const frequency = parseInt(row.frequency || "0");
    resultMap.set(row.value, {
      word: row.value,
      exists: true,
      frequency,
      isRare: frequency < MIN_WORD_FREQUENCY,
    });
  }

  return resultMap;
}

interface BulkSuggestionInput {
  banglaWord: string;
  romanizedWord: string;
}

/**
 * Get spelling suggestions for multiple words in a single query
 * Uses materialized view for frequencies, pg_trgm for similarity, and soundex for phonetic matching
 */
async function getPhoneticSuggestionsBulk(
  inputs: BulkSuggestionInput[],
  limit: number = 10,
): Promise<Map<string, WordSuggestion[]>> {
  if (inputs.length === 0) return new Map();

  const banglaWords = inputs.map((i) => i.banglaWord);
  const romanizedWords = inputs.map((i) => i.romanizedWord.toLowerCase());

  const result = await query<{
    input_word: string;
    id: number;
    value: string;
    romanized: string;
    frequency: string;
    similarity: number;
  }>(
    `
    WITH input_words AS (
      SELECT 
        UNNEST($1::text[]) as bangla_word,
        UNNEST($2::text[]) as romanized_word
    ),
    -- Pre-filter candidate words using indexes
    candidate_words AS (
      SELECT DISTINCT
        iw.bangla_word,
        iw.romanized_word,
        w.id,
        w.value,
        COALESCE(rw.value, '') as romanized,
        COALESCE(wf.freq, 0) as freq
      FROM input_words iw
      CROSS JOIN LATERAL (
        -- Use index-backed similarity search
        SELECT w.id, w.value
        FROM words w
        WHERE length(w.value) BETWEEN 1 AND 50
          AND w.value != iw.bangla_word
          AND (
            w.value % iw.bangla_word  -- trigram similarity operator (uses GIN index)
            OR EXISTS (
              SELECT 1 FROM romanized_words rw2 
              WHERE rw2.word_id = w.id 
              AND (rw2.value % iw.romanized_word OR soundex(rw2.value) = soundex(iw.romanized_word))
            )
          )
        LIMIT 100  -- Limit candidates per input word for performance
      ) w
      LEFT JOIN romanized_words rw ON w.id = rw.word_id
      LEFT JOIN word_frequency_mv wf ON w.id = wf.word_id
      WHERE COALESCE(wf.freq, 0) >= $3
    ),
    scored_words AS (
      SELECT 
        bangla_word as input_word,
        id,
        value,
        romanized,
        freq as frequency,
        LEAST((
          COALESCE(similarity(romanized, romanized_word), 0) * 0.5 + 
          COALESCE(similarity(value, bangla_word), 0) * 0.3 + 
          CASE WHEN soundex(romanized) = soundex(romanized_word) THEN 0.3 ELSE 0 END
        ), 1.0) as similarity,
        CASE WHEN LEAST((
          COALESCE(similarity(romanized, romanized_word), 0) * 0.5 + 
          COALESCE(similarity(value, bangla_word), 0) * 0.3 + 
          CASE WHEN soundex(romanized) = soundex(romanized_word) THEN 0.3 ELSE 0 END
        ), 1.0) >= 0.5 THEN 1 ELSE 0 END as is_high_match
      FROM candidate_words
    ),
    ranked_words AS (
      SELECT 
        input_word,
        id,
        value,
        romanized,
        frequency,
        similarity,
        ROW_NUMBER() OVER (
          PARTITION BY input_word 
          ORDER BY 
            is_high_match DESC,
            CASE WHEN is_high_match = 1 THEN frequency ELSE 0 END DESC,
            similarity DESC
        ) as rank
      FROM scored_words
    )
    SELECT 
      input_word,
      id,
      value,
      romanized,
      frequency::text,
      similarity
    FROM ranked_words
    WHERE rank <= $4
    ORDER BY input_word, rank
    `,
    [banglaWords, romanizedWords, MIN_WORD_FREQUENCY, limit],
  );

  // Group results by input word
  const resultMap = new Map<string, WordSuggestion[]>();

  // Initialize empty arrays for all input words
  for (const input of inputs) {
    resultMap.set(input.banglaWord, []);
  }

  // Populate with results
  for (const row of result) {
    const suggestions = resultMap.get(row.input_word) || [];
    suggestions.push({
      id: row.id,
      value: row.value,
      romanized: row.romanized,
      similarity: row.similarity,
      frequency: parseInt(row.frequency || "0"),
    });
    resultMap.set(row.input_word, suggestions);
  }

  return resultMap;
}

/**
 * POST /api/spell-check
 * Check spelling and get suggestions for Bangla text
 * Uses bulk queries for efficiency
 */
export async function POST(request: NextRequest) {
  try {
    await ensureExtensions();

    const body = await request.json();
    const { text } = body as { text: string };

    if (!text || typeof text !== "string") {
      return NextResponse.json({ error: "Text is required" }, { status: 400 });
    }

    // Split text into words (handle Bangla punctuation)
    const allWords = text
      .split(/[\s।,!?;:'"()[\]{}।॥]+/)
      .filter((w) => w.length > 0);

    // Separate Bangla and non-Bangla words
    const banglaWords: string[] = [];
    const wordInfo: { word: string; isBangla: boolean; romanized: string }[] =
      [];

    for (const word of allWords) {
      const isBangla = /[\u0980-\u09FF]/.test(word);
      const romanized = isBangla ? transliterate(word, { mode: "orva" }) : word;
      wordInfo.push({ word, isBangla, romanized });
      if (isBangla) {
        banglaWords.push(word);
      }
    }

    // Bulk check all Bangla words
    const wordCheckResults = await checkWordsBulk(banglaWords);

    // Find words that need suggestions (don't exist or are rare)
    const wordsNeedingSuggestions: BulkSuggestionInput[] = [];
    for (const info of wordInfo) {
      if (!info.isBangla) continue;
      const checkResult = wordCheckResults.get(info.word);
      if (!checkResult?.exists || checkResult.isRare) {
        wordsNeedingSuggestions.push({
          banglaWord: info.word,
          romanizedWord: info.romanized,
        });
      }
    }

    // Bulk get suggestions for all words that need them
    const suggestionsMap = await getPhoneticSuggestionsBulk(
      wordsNeedingSuggestions,
    );

    // Build final results
    const results: SpellCheckResult[] = wordInfo.map((info) => {
      if (!info.isBangla) {
        return {
          word: info.word,
          isCorrect: true,
          suggestions: [],
          romanized: info.romanized,
        };
      }

      const checkResult = wordCheckResults.get(info.word);
      const exists = checkResult?.exists ?? false;
      const isRare = checkResult?.isRare ?? false;

      if (exists && !isRare) {
        return {
          word: info.word,
          isCorrect: true,
          suggestions: [],
          romanized: info.romanized,
        };
      }

      return {
        word: info.word,
        isCorrect: false,
        suggestions: suggestionsMap.get(info.word) || [],
        romanized: info.romanized,
        isRareWord: exists && isRare,
      };
    });

    return NextResponse.json({
      success: true,
      results,
      totalWords: allWords.length,
      incorrectWords: results.filter((r) => !r.isCorrect).length,
      rareWords: results.filter((r) => r.isRareWord).length,
    });
  } catch (error) {
    console.error("Spell check error:", error);
    return NextResponse.json(
      { error: "Internal server error", details: String(error) },
      { status: 500 },
    );
  }
}

/**
 * GET /api/spell-check
 * Health check endpoint
 */
export async function GET() {
  try {
    await ensureExtensions();

    // Test database connection
    const result = await query<{ count: string }>(
      `SELECT COUNT(*) as count FROM words`,
    );

    return NextResponse.json({
      status: "healthy",
      wordCount: parseInt(result[0]?.count || "0"),
      extensions: ["pg_trgm", "fuzzystrmatch"],
    });
  } catch (error) {
    return NextResponse.json(
      { status: "error", error: String(error) },
      { status: 500 },
    );
  }
}
