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
 *
 * #### Modes:
 *
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

function avro(text: string) {
  const fixed = phonetic.fixString(text);
  let output = "";
  for (let cur = 0; cur < fixed.length; ++cur) {
    const start = cur;
    let end = cur + 1;
    let prev = start - 1;
    let matched = false;

    for (const pattern of rules.patterns) {
      end = cur + pattern.find.length;
      if (end <= fixed.length && fixed.substring(start, end) == pattern.find) {
        prev = start - 1;
        if (typeof pattern.rules !== "undefined") {
          for (const rawRule of pattern.rules) {
            const rule = rawRule as typeof rawRule & {
              matches: (typeof rawRule.matches)[0] &
                {
                  negative?: boolean;
                  value?: string;
                  scope?: string;
                }[];
            };
            let replace = true;
            let chk = 0;

            for (const match of rule.matches) {
              if (match.type === "suffix") {
                chk = end;
              }
              // Prefix
              else {
                chk = prev;
              }

              // Handle Negative
              if (typeof match.negative === "undefined") {
                match.negative = false;
                if (match.scope.charAt(0) === "!") {
                  match.negative = true;
                  match.scope = match.scope.substring(1);
                }
              }

              // Handle empty value
              // @ts-expect-error: TODO: fix this
              if (typeof match.value === "undefined") match.value = "";

              // Beginning
              if (match.scope === "punctuation") {
                if (
                  !(
                    (chk < 0 && match.type === "prefix") ||
                    (chk >= fixed.length && match.type === "suffix") ||
                    phonetic.isPunctuation(fixed.charAt(chk))
                  ) !== match.negative
                ) {
                  replace = false;
                  break;
                }
              }
              // Vowel
              else if (match.scope === "vowel") {
                if (
                  !(
                    ((chk >= 0 && match.type === "prefix") ||
                      (chk < fixed.length && match.type === "suffix")) &&
                    phonetic.isVowel(fixed.charAt(chk))
                  ) !== match.negative
                ) {
                  replace = false;
                  break;
                }
              }
              // Consonant
              else if (match.scope === "consonant") {
                if (
                  !(
                    ((chk >= 0 && match.type === "prefix") ||
                      (chk < fixed.length && match.type === "suffix")) &&
                    phonetic.isConsonant(fixed.charAt(chk))
                  ) !== match.negative
                ) {
                  replace = false;
                  break;
                }
              }
              // Exact
              else if (match.scope === "exact") {
                let s, e;
                if (match.type === "suffix") {
                  s = end;
                  e = end + match.value.length;
                }
                // Prefix
                else {
                  s = start - match.value.length;
                  e = start;
                }
                if (
                  !phonetic.isExact(match.value, fixed, s, e, match.negative)
                ) {
                  replace = false;
                  break;
                }
              }
            }

            if (replace) {
              output += rule.replace;
              cur = end - 1;
              matched = true;
              break;
            }
          }
        }
        if (matched == true) break;

        // Default
        output += pattern.replace;
        cur = end - 1;
        matched = true;
        break;
      }
    }

    if (!matched) {
      output += fixed.charAt(cur);
    }
  }
  return output;
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
