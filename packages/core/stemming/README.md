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

### Basic Usage

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

### Backward Compatibility

For backward compatibility, the default export still provides the original API:

```typescript
import banglaStemmer from "@bntk/stemming";

const stemmed = banglaStemmer.stem("অসুবিধাগুলো");
console.log(stemmed); // 'সুবিধা'

const stemmedWords = banglaStemmer.stemWords(["প্রতিদিন", "মানুষের"]);
console.log(stemmedWords); // ['দিন', 'মানুষ']
```

## API Reference

### `stemWord(word: string): string`

Stems a single Bangla word by removing prefixes and suffixes.

### `stemWords(words: string[]): string[]`

Stems an array of Bangla words and returns an array of stemmed words.

### `removePrefix(word: string): string`

Removes a matching prefix from a word if found.

### `removeSuffix(word: string): string`

Removes a matching suffix from a word if found.

## Running Tests

```bash
# Using Bun
bun test
```

## Data Source

The stemming data is sourced from the `stemming.json` file which contains lists of Bangla prefixes and suffixes.

## License

MIT
