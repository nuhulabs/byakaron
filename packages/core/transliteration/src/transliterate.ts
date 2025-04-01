import * as rules from "../assets/rules.json";
import { phonetic } from "./phonetic";

/**
 * Transliteration mode for Avro Phonetic keyboard layout.
 *
 * Avro Phonetic is the most widely used phonetic typing method for Bangla text.
 * It follows intuitive phonetic rules where you type words exactly as they sound.
 */
type TransliterationOptionModeAvro = {
  mode: "avro";
};

/**
 * Transliteration mode for Orva (Reverse Avro) layout.
 *
 * Orva performs reverse transliteration from Bangla script to romanized text.
 * It's particularly useful for converting Bangla text into a Latin alphabet representation.
 */
type TransliterationOptionModeOrva = {
  mode: "orva";
};

/**
 * Transliteration mode for Banglish layout.
 *
 * Banglish is an informal phonetic typing system that matches common patterns
 * used in digital communications when writing Bangla words with English characters.
 */
type TransliterationOptionModeBanglish = {
  mode: "banglish";
};

/**
 * Transliteration mode for Lishbang (Latin-to-Bangla) layout.
 *
 * Lishbang is designed to be intuitive for English speakers while maintaining
 * accurate Bangla pronunciation rules. It uses systematic Latin character mappings
 * that closely match Bangla phonetics.
 */
type TransliterationOptionModeLishbang = {
  mode: "lishbang";
};

/**
 * Configuration options for the Bangla text transliteration process.
 *
 * The transliteration system supports multiple modes to accommodate different
 * typing preferences and use cases. Each mode is optimized for specific scenarios,
 * from formal typing to casual communication.
 *
 * @see {@link TransliterationOptionModeAvro} for the popular Avro Phonetic system
 * @see {@link TransliterationOptionModeOrva} for reverse transliteration
 * @see {@link TransliterationOptionModeBanglish} for informal typing
 * @see {@link TransliterationOptionModeLishbang} for English-speaker friendly typing
 */
type TransliterationOptions =
  | TransliterationOptionModeAvro
  | TransliterationOptionModeOrva
  | TransliterationOptionModeBanglish
  | TransliterationOptionModeLishbang;

/**
 * Transliterates text between Bangla and Latin scripts using various modes.
 * @modes
 * - #### avro
 * Most popular phonetic typing system for Bangla
 *   ```typescript
 *   transliterate("amar sOnar bangla", { mode: "avro" }) // → "আমার সোনার বাংলা"
 *   transliterate("jIbon", { mode: "avro" }) // → "জীবন"
 *   ```
 *
 * - #### orva
 *  Reverse transliteration from Bangla to Latin script (beta)
 *   ```typescript
 *   transliterate("আমার সোনার বাংলা", { mode: "orva" }) // → "amar sOnar bangla"
 *   transliterate("জীবন", { mode: "orva" }) // → "jIbon"
 *   ```
 *
 * - #### banglish
 * Informal phonetic system matching common texting patterns (not yet implemented)
 *   ```typescript
 *   transliterate("amar shonar bangla", { mode: "banglish" }) // → "আমার সোনার বাংলা"
 *   transliterate("jibon", { mode: "banglish" }) // → "জীবন"
 *   ```
 *
 * - #### lishbang
 * English-speaker friendly system with systematic mappings (not yet implemented)
 *   ```typescript
 *   transliterate("ইট ইজ নট গুড।", { mode: "lishbang" })     // → "It is not good."
 *   transliterate("মাই নেইম ইজ আপন।", { mode: "lishbang" }) // → "My name is Apon."
 *   ```
 *
 * @param {string} text - The input text to transliterate
 * @param {TransliterationOptions} options - Configuration options with desired mode
 * @returns {string} The transliterated text
 */
export function transliterate(
  text: string,
  options: TransliterationOptions = { mode: "avro" },
) {
  const fn = MODE_TRANSLITERATION_FUNCTIONS[options.mode];
  if (!fn) {
    throw new Error(
      "Invalid mode. Available modes are: 'avro', 'orva', 'banglish', 'lishbang'",
    );
  }
  return fn(text);
}

const MODE_TRANSLITERATION_FUNCTIONS = {
  avro: avro,
  orva: orva,
  banglish: banglish,
  lishbang: lishbang,
} as const;

/**
 * Cache for pattern matching results to avoid repeated computations
 */
const patternMatchCache = new Map<
  string,
  {
    pattern: (typeof rules.patterns)[0];
    endIndex: number;
  }
>();

/**
 * Converts text using the Avro Phonetic system with optimized performance
 */
function avro(text: string): string {
  const fixed = phonetic.fixString(text);
  const output: string[] = []; // Using array for faster string concatenation
  const len = fixed.length;

  // Pre-calculate pattern lengths for faster matching
  const patternsWithLength = rules.patterns.map((pattern) => ({
    pattern,
    length: pattern.find.length,
  }));

  for (let currentIndex = 0; currentIndex < len; ++currentIndex) {
    const startIndex = currentIndex;
    let isMatched = false;

    // Try to match from cache first
    const cacheKey = fixed.slice(startIndex, startIndex + 8); // Cache key with reasonable length
    const cachedMatch = patternMatchCache.get(cacheKey);

    if (cachedMatch) {
      const { pattern, endIndex } = cachedMatch;
      if (
        endIndex <= len &&
        fixed.substring(startIndex, endIndex) === pattern.find
      ) {
        const result = processPattern(
          pattern,
          fixed,
          startIndex,
          endIndex,
          currentIndex,
        );
        if (result.isMatched) {
          output.push(result.output);
          currentIndex = result.newIndex;
          continue;
        }
      }
    }

    // No cache hit, try matching patterns
    for (const { pattern, length } of patternsWithLength) {
      const endIndex = currentIndex + length;

      if (endIndex > len) continue; // Skip if pattern is too long

      const segment = fixed.substring(startIndex, endIndex);
      if (segment === pattern.find) {
        // Cache this successful match for future use
        patternMatchCache.set(cacheKey, { pattern, endIndex });

        const result = processPattern(
          pattern,
          fixed,
          startIndex,
          endIndex,
          currentIndex,
        );
        if (result.isMatched) {
          output.push(result.output);
          currentIndex = result.newIndex;
          isMatched = true;
          break;
        }
      }
    }

    if (!isMatched) {
      output.push(fixed.charAt(currentIndex));
    }
  }

  return output.join("");
}

/**
 * Optimized pattern processing with minimal object creation
 */
function processPattern(
  pattern: (typeof rules.patterns)[0],
  fixed: string,
  startIndex: number,
  endIndex: number,
  currentIndex: number,
): { isMatched: boolean; output: string; newIndex: number } {
  if (!pattern.rules) {
    return {
      isMatched: true,
      output: pattern.replace,
      newIndex: endIndex - 1,
    };
  }

  const previousIndex = startIndex - 1;

  for (const rule of pattern.rules) {
    let shouldReplace = true;

    for (const match of rule.matches) {
      const checkIndex = match.type === "suffix" ? endIndex : previousIndex;

      // Handle negative matching
      const isNegative = match.scope?.charAt(0) === "!";
      const scope = isNegative ? match.scope.substring(1) : match.scope;

      // Fast path for common cases
      switch (scope) {
        case "punctuation": {
          const isPunctuation =
            (checkIndex < 0 && match.type === "prefix") ||
            (checkIndex >= fixed.length && match.type === "suffix") ||
            phonetic.isPunctuation(fixed.charAt(checkIndex));
          if (isPunctuation === isNegative) {
            shouldReplace = false;
          }
          break;
        }
        case "vowel": {
          const isVowelMatch =
            ((checkIndex >= 0 && match.type === "prefix") ||
              (checkIndex < fixed.length && match.type === "suffix")) &&
            phonetic.isVowel(fixed.charAt(checkIndex));
          if (isVowelMatch === isNegative) {
            shouldReplace = false;
          }
          break;
        }
        case "consonant": {
          const isConsonantMatch =
            ((checkIndex >= 0 && match.type === "prefix") ||
              (checkIndex < fixed.length && match.type === "suffix")) &&
            phonetic.isConsonant(fixed.charAt(checkIndex));
          if (isConsonantMatch === isNegative) {
            shouldReplace = false;
          }
          break;
        }
        case "exact": {
          const [s, e] =
            match.type === "suffix"
              ? [endIndex, endIndex + (match.value?.length || 0)]
              : [startIndex - (match.value?.length || 0), startIndex];

          if (!phonetic.isExact(match.value || "", fixed, s, e, isNegative)) {
            shouldReplace = false;
          }
          break;
        }
      }

      if (!shouldReplace) break;
    }

    if (shouldReplace) {
      return {
        isMatched: true,
        output: rule.replace,
        newIndex: endIndex - 1,
      };
    }
  }

  return {
    isMatched: true,
    output: pattern.replace,
    newIndex: endIndex - 1,
  };
}

function orva(text: string) {
  // Create a reverse mapping from Bengali to Roman characters
  const reversePatterns = rules.patterns
    .filter(
      (pattern) =>
        // Filter out patterns that would cause loops or are invalid for reverse mapping
        pattern.replace &&
        pattern.find &&
        pattern.replace.length > 0 &&
        pattern.find.length > 0,
    )
    // exclude non relevant txt
    .filter((pattern) => pattern.find !== "o" && pattern.replace !== "")
    .map((pattern) => ({
      find: pattern.replace,
      replace: pattern.find,
      rules: pattern.rules,
    }))
    .sort((a, b) => b.find.length - a.find.length); // Sort by length descending for proper matching

  let output = "";
  let maxIterations = text.length * 2; // Safety counter
  let iterations = 0;

  for (let cur = 0; cur < text.length; ++cur) {
    iterations++;
    if (iterations > maxIterations) {
      console.warn(
        "Orva transliteration exceeded maximum iterations, breaking to prevent infinite loop",
      );
      break;
    }

    const start = cur;
    let matched = false;

    // Try to match patterns
    for (const pattern of reversePatterns) {
      const end = cur + pattern.find.length;

      // Skip invalid patterns
      if (end > text.length) continue;

      const segment = text.substring(start, end);
      if (segment === pattern.find) {
        output += pattern.replace;
        cur = end - 1; // Move cursor to end of matched pattern
        matched = true;
        break;
      }
    }

    // If no pattern matches, keep the original character
    if (!matched) {
      output += text.charAt(cur);
    }
  }
  return output
    .replaceAll("`", "")
    .replaceAll("আ", "a")
    .replaceAll("অ", "o")
    .replaceAll("ই", "i")
    .replaceAll("ঈ", "e")
    .replaceAll("উ", "u")
    .replaceAll("এ", "e")
    .replaceAll("্", "")
    .replaceAll("়", "")
    .replaceAll("উ", "u");
}

function banglish(text: string): string {
  throw new Error("Banglish transliteration is not implemented yet");
}

function lishbang(text: string): string {
  throw new Error("Lishbang transliteration is not implemented yet");
}
