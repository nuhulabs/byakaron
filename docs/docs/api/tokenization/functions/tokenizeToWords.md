# tokenizeToWords()

```ts
function tokenizeToWords(text): string[];
```

Defined in: [word.ts:57](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/tokenization/src/word.ts#L57)

Tokenizes a Bangla text string into an array of words.

## Parameters

| Parameter | Type     | Description                                                                                                |
| --------- | -------- | ---------------------------------------------------------------------------------------------------------- |
| `text`    | `string` | The input Bangla text to tokenize. Can contain mixed content including punctuation and special characters. |

## Returns

`string`[]

An array of cleaned and tokenized words, with empty strings removed.

## Description

This function performs the following steps:

1. Cleans the input text by:
   - Removing non-Bangla characters (keeping only Unicode range: \u0980-\u09FF)
   - Preserving essential punctuation marks (।, ,, ;, :, ', ", ?, !)
   - Preserving hyphens for compound words
2. Splits the text by whitespace
3. Further splits each segment by punctuation (excluding hyphens)
4. Cleans each word by:
   - Removing trailing hyphens
   - Removing Bangla digits from start and end
   - Trimming whitespace
5. Filters out empty strings

## Examples

Basic usage with simple Bangla text:

```typescript
const text = "আমি বাংলায় গান গাই";
const words = tokenizeToWords(text);
console.log(words);
// Output: ["আমি", "বাংলায়", "গান", "গাই"]
```

Handling text with punctuation:

```typescript
const text = "আমি, বাংলায় গান গাই। তুমি কি শুনবে?";
const words = tokenizeToWords(text);
console.log(words);
// Output: ["আমি", "বাংলায়", "গান", "গাই", "তুমি", "কি", "শুনবে"]
```

Handling compound words with hyphens:

```typescript
const text = "আমি-তুমি বাংলা-ভাষা শিখছি";
const words = tokenizeToWords(text);
console.log(words);
// Output: ["আমি-তুমি", "বাংলা-ভাষা", "শিখছি"]
```

Handling text with Bangla digits:

```typescript
const text = "১টি বই ২টি খাতা";
const words = tokenizeToWords(text);
console.log(words);
// Output: ["টি", "বই", "টি", "খাতা"]
```
