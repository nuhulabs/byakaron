import * as rules from "../assets/rules.json";
import { phonetic } from "./phonetic";

/**
 * Transliterates Bangla text written in English (romanized) to Bangla script,
 * following the Avro Phonetic typing method.
 *
 * @param {string} text - The input text in English characters to convert to Bangla script
 * @returns {string} The transliterated text in Bangla script
 *
 * @example
 * // Basic transliteration
 * transliterate("ami bangla likhi");
 * // Returns: "আমি বাংলা লিখি"
 *
 * @example
 * // Conjunct consonants (juktakkhor)
 * transliterate("kSto");
 * // Returns: "ক্ষ্ট"
 *
 * @example
 * // Special characters
 * transliterate("amar kachhe 500 taka ache.");
 * // Returns: "আমার কাছে ৫০০ টাকা আছে।"
 *
 * @example
 * // Vowel combinations
 * transliterate("aei");
 * // Returns: "আঈ"
 *
 * @example
 * // Mixed English and Bangla
 * transliterate("ami website e login korlam");
 * // Returns: "আমি ওয়েবসাইট এ লগিন করলাম"
 */
export function transliterate(text: string) {
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
