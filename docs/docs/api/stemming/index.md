# @bntk/stemming

A Bangla (Bengali) language stemmer implementation that removes prefixes and suffixes from Bangla words based on predefined lists.

## Features

- Removes common Bangla prefixes (e.g., 'প্র', 'অতি', 'উপ', etc.)
- Removes common Bangla suffixes (e.g., 'ের', 'গুলো', 'ীয়', etc.)
- Sorts prefixes and suffixes by length to ensure the longest matches are removed first
- Provides functions for stemming individual words or arrays of words
- Built with TypeScript for type safety
- Functional approach with no class instantiation required

## Installation

```bash
npm install @bntk/stemming
# or
bun add @bntk/stemming
```

## Usage

```typescript
import { stemWord, stemWords } from "@bntk/stemming";

// Stem a single word
const stemmed = stemWord("অসুবিধাগুলো");
console.log(stemmed); // Expected output: 'সুবিধা'

// Stem an array of words
const words = ["প্রতিদিন", "মানুষের", "দেখছিলাম"];
const stemmedWords = stemWords(words);
console.log(stemmedWords); // Expected output: ['দিন', 'মানুষ', 'দেখ']
```

### Using Individual Functions

```typescript
import { removePrefix, removeSuffix } from "@bntk/stemming";

// Remove only a prefix
const withoutPrefix = removePrefix("প্রতিদিন");
console.log(withoutPrefix); // 'দিন'

// Remove only a suffix
const withoutSuffix = removeSuffix("মানুষের");
console.log(withoutSuffix); // 'মানুষ'
```

## Functions

- [removePrefix](functions/removePrefix.md)
- [removeSuffix](functions/removeSuffix.md)
- [stemWord](functions/stemWord.md)
- [stemWords](functions/stemWords.md)
