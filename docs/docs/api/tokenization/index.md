# 📦 @bntk/tokenization

A TypeScript package for tokenizing Bangla text into words and sentences.

## Features

- Word tokenization with proper handling of Bangla punctuation and separators
- Sentence tokenization with support for Bangla sentence endings
- Comprehensive text cleaning and normalization
- TypeScript support with full type definitions
- Handles complex Bangla text patterns and special cases

## Installation

```bash npm2yarn
npm install @bntk/tokenization
```

## Usage

```typescript
import { tokenizeToSentences, tokenizeToWords } from "@bntk/tokenization";

// Tokenize words
const text = "আমি বাংলায় গান গাই";
const words = tokenizeToWords(text);
console.log(words);
// Output: ["আমি", "বাংলায়", "গান", "গাই"]

// Tokenize sentences
const paragraph = "আমি বাংলায় গান গাই। তুমি কি শুনবে?";
const sentences = tokenizeToSentences(paragraph);
console.log(Array.from(sentences));
// Output: ["আমি বাংলায় গান গাই", "তুমি কি শুনবে"]
```

## Functions

- [tokenizeToSentences](functions/tokenizeToSentences.md)
- [tokenizeToWords](functions/tokenizeToWords.md)
