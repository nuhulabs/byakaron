# tagWords()

```ts
function tagWords(words): TaggedWord[];
```

Defined in: [index.ts:134](https://github.com/nurulhudaapon/bntk/blob/3b9fe22b211144284ee58f4d31328c8e4ae31d1e/packages/core/pos/src/index.ts#L134)

Tags a sequence of Bangla words with their parts of speech

## Parameters

| Parameter | Type       | Description                  |
| --------- | ---------- | ---------------------------- |
| `words`   | `string`[] | Array of Bangla words to tag |

## Returns

[`TaggedWord`](../interfaces/TaggedWord.md)[]

Array of words with their POS tags and features

## Description

This function performs POS tagging for a sequence of Bangla words.
It takes into account the context of surrounding words to improve
tagging accuracy.

## Example

```typescript
const words = ["আমি", "বাংলায়", "গান", "গাই"];
const tagged = tagWords(words);
console.log(tagged);
// Output: [
//   { word: "আমি", tag: UniversalPOSTag.PRON },
//   { word: "বাংলায়", tag: UniversalPOSTag.ADP },
//   { word: "গান", tag: UniversalPOSTag.NOUN },
//   { word: "গাই", tag: UniversalPOSTag.VERB }
// ]
```
