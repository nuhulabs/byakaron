# 📦 @bntk/tokenization

## tokenizeToSentences()

```ts
function tokenizeToSentences(text): string[];
```

Defined in: [sentence.ts:50](https://github.com/nurulhudaapon/bntk/blob/a800a88ba2a08067633bfe63793a7c8b86a8a486/packages/core/tokenization/src/sentence.ts#L50)

Tokenizes a Bangla text into an array of sentences.

### Parameters

| Parameter | Type     | Description                                                                                                  |
| --------- | -------- | ------------------------------------------------------------------------------------------------------------ |
| `text`    | `string` | The input Bangla text to tokenize. Can contain mixed content including URLs, emails, and special characters. |

### Returns

`string`[]

An array of cleaned and tokenized sentences, with duplicates removed.

### Description

This function performs the following steps:

1. Splits text by line breaks
2. Further splits by Bangla sentence separators
3. Cleans each sentence by:
   - Removing text within parentheses, brackets, braces, and angle brackets
   - Removing URLs and email addresses
   - Removing HTML entities
   - Removing Latin characters
   - Keeping only Bangla characters, spaces, and essential punctuation
   - Normalizing spaces and punctuation
4. Filters sentences based on the following criteria:
   - Must contain Bangla characters (Unicode range: \u0980-\u09FF)
   - Must have more than 3 words
   - Must not be empty
5. Returns a Set to remove duplicates

### Examples

Basic usage with simple Bangla text:

```typescript
const text = "আমি বাংলায় গান গাই। তুমি কি শুনবে?";
console.log(tokenizeToSentences(text));
// Output: ["আমি বাংলায় গান গাই", "তুমি কি শুনবে"]
```

Handling mixed content:

```typescript
const mixedText =
  "আমি বাংলায় গান গাই। Visit https://example.com or email@example.com";
console.log(tokenizeToSentences(mixedText));
// Output: ["আমি বাংলায় গান গাই"]
```

Handling text with special characters:

```typescript
const specialText =
  "বাংলা টেক্সট (ইংরেজি টেক্সট) [বন্ধনী টেক্সট] {কোঁকড়া টেক্সট}";
console.log(tokenizeToSentences(specialText));
// Output: ["বাংলা টেক্সট"]
```

---

## tokenizeToWords()

```ts
function tokenizeToWords(text): string[];
```

Defined in: [word.ts:57](https://github.com/nurulhudaapon/bntk/blob/a800a88ba2a08067633bfe63793a7c8b86a8a486/packages/core/tokenization/src/word.ts#L57)

Tokenizes a Bangla text string into an array of words.

### Parameters

| Parameter | Type     | Description                                                                                                |
| --------- | -------- | ---------------------------------------------------------------------------------------------------------- |
| `text`    | `string` | The input Bangla text to tokenize. Can contain mixed content including punctuation and special characters. |

### Returns

`string`[]

An array of cleaned and tokenized words, with empty strings removed.

### Description

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

### Examples

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
