# tokenizeToSentences()

```ts
function tokenizeToSentences(text): string[];
```

Defined in: [sentence.ts:50](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/tokenization/src/sentence.ts#L50)

Tokenizes a Bangla text into an array of sentences.

## Parameters

| Parameter | Type     | Description                                                                                                  |
| --------- | -------- | ------------------------------------------------------------------------------------------------------------ |
| `text`    | `string` | The input Bangla text to tokenize. Can contain mixed content including URLs, emails, and special characters. |

## Returns

`string`[]

An array of cleaned and tokenized sentences, with duplicates removed.

## Description

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

## Examples

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
