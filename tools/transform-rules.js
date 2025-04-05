/**
 * Reverse Transliteration Rules Generator
 *
 * This script reads the original transliteration rules from rules.json
 * and creates a reversed version where the find/replace values are swapped.
 *
 * The resulting reversed-rules.json can be used to convert from Bengali
 * characters back to Latin characters (reverse transliteration).
 *
 * Usage:
 * 1. Make sure packages/core/transliteration/assets/rules.json exists
 * 2. Run: node reversed-rules.js
 * 3. The output will be saved as reversed-rules.json in the current directory
 */
import fs from "fs";

// Read the original rules.json file
const rulesContent = fs.readFileSync(
  "./packages/core/transliteration/assets/rules.json",
  "utf8",
);
const rules = JSON.parse(rulesContent);

// Create a new object for reversed rules
const reversedRules = {
  vowel: rules.vowel,
  consonant: rules.consonant,
  casesensitive: rules.casesensitive,
  patterns: [],
};

// Function to create a map of patterns to help with duplicates
function createPatternMap() {
  const patternMap = new Map();

  rules.patterns.forEach((pattern) => {
    // For simple patterns
    if (!pattern.rules) {
      if (!patternMap.has(pattern.replace)) {
        patternMap.set(pattern.replace, []);
      }
      patternMap.get(pattern.replace).push({
        find: pattern.find,
        hasRules: false,
        originalPattern: pattern,
      });
    }
  });

  return patternMap;
}

const patternMap = createPatternMap();

// Reverse find and replace for each pattern
rules.patterns.forEach((pattern) => {
  // Simple pattern with just find and replace
  if (!pattern.rules) {
    reversedRules.patterns.push({
      find: pattern.replace,
      replace: pattern.find,
    });
  }
  // Complex pattern with rules
  else {
    // For complex patterns, we need to be more careful about the rules
    const reversedPattern = {
      find: pattern.replace,
      replace: pattern.find,
      rules: [],
    };

    // For each rule in the original pattern, we create a reversed rule
    // that swaps the conditional replacement
    pattern.rules.forEach((rule) => {
      const reversedRule = {
        matches: [...rule.matches], // Clone the matches array
        replace: pattern.find, // In the reversed case, we're replacing with the original find value
      };

      reversedPattern.rules.push(reversedRule);
    });

    reversedRules.patterns.push(reversedPattern);
  }
});

// For duplicates in the reversed map (multiple Latin characters mapping to same Bengali char)
// we need to make sure we only keep one entry to avoid conflicts
const uniqueReversedPatterns = [];
const seenFinds = new Set();

reversedRules.patterns.forEach((pattern) => {
  // If this Bengali character hasn't been seen before, or it has complex rules, keep it
  if (!seenFinds.has(pattern.find) || pattern.rules) {
    uniqueReversedPatterns.push(pattern);
    seenFinds.add(pattern.find);
  }
});

// Update the patterns with the unique list
reversedRules.patterns = uniqueReversedPatterns;

// Custom replacer function to format the JSON with patterns as one-liners
function customStringify(obj) {
  // Start with the opening brace
  let result = "{\n";

  // Add the simple properties
  result += `  "vowel": ${JSON.stringify(obj.vowel)},\n`;
  result += `  "consonant": ${JSON.stringify(obj.consonant)},\n`;
  result += `  "casesensitive": ${JSON.stringify(obj.casesensitive)},\n`;

  // Start the patterns array
  result += '  "patterns": [\n';

  // Add each pattern as a one-liner
  for (let i = 0; i < obj.patterns.length; i++) {
    const pattern = obj.patterns[i];
    const patternJson = JSON.stringify(pattern);
    result += `    ${patternJson}`;

    // Add comma if not the last item
    if (i < obj.patterns.length - 1) {
      result += ",";
    }

    result += "\n";
  }

  // Close the patterns array and the object
  result += "  ]\n}";

  return result;
}

// Write the reversed rules to a new file with patterns as one-liners
fs.writeFileSync(
  "./reversed-rules.json",
  customStringify(reversedRules),
  "utf8",
);

console.log(
  "Reversed rules have been created and saved to reversed-rules.json",
);
