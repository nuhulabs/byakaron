# Bangla Spellcheck LSP - Logic Package

This package contains the core logic for the Bangla language spellcheck Language Server Protocol (LSP) implementation. It provides the functionality to check Bangla text for spelling errors and suggest corrections.

## Features

- Bangla text spellchecking
- Spelling error detection
- Suggestion generation for misspelled words
- Customizable dictionary support
- Text normalization for Bangla characters

## Installation

```bash
npm install @bntk/lsp
```

## Usage

```typescript
import { BengaliSpellchecker, TextDocument } from "@bntk/lsp";

// Create a new spellchecker instance
const spellchecker = new BengaliSpellchecker({
  maxSuggestions: 5,
  ignoreWordsWithNumbers: true,
});

// Load a custom dictionary
spellchecker.loadDictionary(["বাংলা", "ভাষা", "অভিধান"]);

// Check a document for spelling errors
const document = TextDocument.create(
  "file:///example.txt",
  "bangla",
  1,
  "আমি বাংলায় কথা বলি।",
);
const spellingErrors = await spellchecker.checkDocument(document);

// Check a single word
const isCorrect = await spellchecker.checkWord("বাংলা");

// Get suggestions for a misspelled word
const suggestions = await spellchecker.getSuggestions("বাংল");
```

## API Reference

### `BengaliSpellchecker`

The main class for spellchecking Bangla text.

#### Constructor

```typescript
constructor(options?: BengaliSpellcheckOptions)
```

Options:

- `customDictionary`: Array of words to add to the dictionary
- `maxSuggestions`: Maximum number of suggestions to provide for misspelled words
- `ignoreWordsWithNumbers`: Whether to ignore words containing numbers
- `ignoreWordsInAllUpperCase`: Whether to ignore words in all uppercase

#### Methods

- `loadDictionary(words: string[]): void` - Load a dictionary of words
- `checkDocument(document: TextDocument): Promise<SpellingError[]>` - Check a document for spelling errors
- `checkWord(word: string): Promise<boolean>` - Check if a word is spelled correctly
- `getSuggestions(word: string): Promise<string[]>` - Get suggestions for a misspelled word

## License

MIT
