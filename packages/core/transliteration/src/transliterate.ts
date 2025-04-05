import * as banglishRules from "../assets/banglish.json";
import * as lishbangRules from "../assets/lishbang.json";
import * as orvaRules from "../assets/orva.json";
import * as avroRules from "../assets/rules.json";
import { createPhonetic } from "./phonetic";
import type { RootRule } from "./types";

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
  if (!fn)
    throw new Error(
      "Invalid mode. Available modes are: 'avro', 'orva', 'banglish', 'lishbang'",
    );

  return fn(text);
}

const MODE_TRANSLITERATION_FUNCTIONS = {
  avro: createTransliterator(avroRules),
  orva: createTransliterator(orvaRules),
  banglish: createTransliterator(banglishRules),
  lishbang: createTransliterator(lishbangRules),
} as const;

/**
 * Cache for pattern matching results to avoid repeated computations
 */
const patternMatchCache = new Map<
  string,
  {
    pattern: RootRule["patterns"][0];
    endIndex: number;
  }
>();

/**
 * Converts text using the Avro Phonetic system with optimized performance
 */
function createTransliterator(rules: RootRule) {
  const phonetic = createPhonetic(rules);
  return (text: string) => {
    const fixed = phonetic.fixString(text);
    const output: string[] = []; // Using array for faster string concatenation
    const len = fixed.length;

    // Pre-calculate pattern lengths for faster matching and filter out empty patterns
    const patternsWithLength = rules.patterns
      .filter((pattern) => pattern.find.length > 0) // Skip empty patterns to avoid infinite loops
      .map((pattern) => ({
        pattern,
        length: pattern.find.length,
      }));

    for (let currentIndex = 0; currentIndex < len; ++currentIndex) {
      const startIndex = currentIndex;
      let isMatched = false;

      // Try to match from cache first
      // const cacheKey = fixed.slice(startIndex, startIndex + 8); // Cache key with reasonable length
      // const cachedMatch = patternMatchCache.get(cacheKey);

      // if (cachedMatch) {
      //   const { pattern, endIndex } = cachedMatch;
      //   if (
      //     endIndex <= len &&
      //     fixed.substring(startIndex, endIndex) === pattern.find
      //   ) {
      //     const result = processPattern(
      //       pattern,
      //       fixed,
      //       startIndex,
      //       endIndex,
      //       currentIndex,
      //       phonetic,
      //     );
      //     if (result.isMatched) {
      //       output.push(result.output);
      //       currentIndex = result.newIndex;
      //       continue;
      //     }
      //   }
      // }

      // No cache hit, try matching patterns
      for (const { pattern, length } of patternsWithLength) {
        const endIndex = currentIndex + length;

        if (endIndex > len) continue; // Skip if pattern is too long
        if (length === 0) continue; // Skip empty patterns to prevent infinite loops

        const segment = fixed.substring(startIndex, endIndex);
        if (segment === pattern.find) {
          // Cache this successful match for future use
          // patternMatchCache.set(cacheKey, { pattern, endIndex });

          const result = processPattern(
            pattern,
            fixed,
            startIndex,
            endIndex,
            currentIndex,
            phonetic,
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
  };
}

/**
 * Optimized pattern processing with minimal object creation
 */
function processPattern(
  pattern: RootRule["patterns"][0],
  fixed: string,
  startIndex: number,
  endIndex: number,
  currentIndex: number,
  phonetic: ReturnType<typeof createPhonetic>,
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
      const isPrefix = match.type === "prefix";
      const isSuffix = match.type === "suffix";

      // Fast path for common cases
      switch (scope) {
        case "punctuation": {
          const isPunctuation =
            (isPrefix && checkIndex < 0) ||
            (isSuffix && checkIndex >= fixed.length) ||
            phonetic.isPunctuation(fixed.charAt(checkIndex));
          if (isPunctuation === isNegative) {
            shouldReplace = false;
          }
          break;
        }
        case "vowel": {
          const isVowelMatch =
            ((isPrefix && checkIndex >= 0) ||
              (isSuffix && checkIndex < fixed.length)) &&
            phonetic.isVowel(fixed.charAt(checkIndex));
          if (isVowelMatch === isNegative) {
            shouldReplace = false;
          }
          break;
        }
        case "consonant": {
          const isConsonantMatch =
            ((isPrefix && checkIndex >= 0) ||
              (isSuffix && checkIndex < fixed.length)) &&
            phonetic.isConsonant(fixed.charAt(checkIndex));
          if (isConsonantMatch === isNegative) {
            shouldReplace = false;
          }
          break;
        }
        case "exact": {
          const [s, e] = isSuffix
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
