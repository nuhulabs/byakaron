# Bangla Text Tokenization

A TypeScript package for tokenizing Bangla text into words and sentences.

## Features

- Word tokenization with proper handling of Bangla punctuation and separators
- Sentence tokenization with support for Bangla sentence endings
- Comprehensive text cleaning and normalization
- TypeScript support with full type definitions
- Handles complex Bangla text patterns and special cases

## Installation

```bash
bun add @bntk/tokenization
# or
npm install @bntk/tokenization
# or
yarn add @bntk/tokenization
# or
pnpm add @bntk/tokenization
```

## Quick Start

```typescript
import { tokenizeToWords, tokenizeToSentences } from '@bntk/tokenization';

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

## API Reference

For detailed API documentation, please refer to the auto-generated documentation.

## Features in Detail

### Word Tokenization
- Handles Bangla punctuation marks
- Preserves hyphenated words
- Removes unwanted characters and normalizes text
- Filters out empty strings and invalid tokens

### Sentence Tokenization
- Supports Bangla sentence endings (।, ?, !)
- Handles line breaks and multiple separators
- Filters out invalid or too short sentences
- Removes duplicate sentences

### Text Cleaning
- Removes non-Bangla characters
- Normalizes whitespace and punctuation
- Handles special cases like URLs and email addresses
- Preserves essential Bangla punctuation

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details. 