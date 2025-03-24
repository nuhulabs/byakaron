# 📦 @bntk/stemming

:::note

See the [comprehensive documentation](https://bangla-toolkit.github.io/bntk-core/docs/api) for detailed API reference and examples.

:::

A Bangla (Bengali) language stemmer implementation that removes prefixes and suffixes from Bangla words based on predefined lists.

## Features

- Removes common Bangla prefixes (e.g., 'প্র', 'অতি', 'উপ', etc.)
- Removes common Bangla suffixes (e.g., 'ের', 'গুলো', 'ীয়', etc.)
- Sorts prefixes and suffixes by length to ensure the longest matches are removed first
- Provides functions for stemming individual words or arrays of words
- Built with TypeScript for type safety
- Functional approach with no class instantiation required

## Installation

```bash npm2yarn
npm install @bntk/stemming
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

## Functions

- [removePrefix](functions/removePrefix.md)
- [removeSuffix](functions/removeSuffix.md)
- [stemWord](functions/stemWord.md)
- [stemWords](functions/stemWords.md)
