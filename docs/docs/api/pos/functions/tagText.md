# tagText()

```ts
function tagText(text): TaggedWord[];
```

Defined in: [index.ts:162](https://github.com/nurulhudaapon/bntk/blob/3b9fe22b211144284ee58f4d31328c8e4ae31d1e/packages/core/pos/src/index.ts#L162)

Tags a Bangla text string with parts of speech

## Parameters

| Parameter | Type     | Description            |
| --------- | -------- | ---------------------- |
| `text`    | `string` | The Bangla text to tag |

## Returns

[`TaggedWord`](../interfaces/TaggedWord.md)[]

Array of words with their POS tags and features

## Description

This function first tokenizes the input text into words and then
performs POS tagging on the resulting word sequence.

## Example

```typescript
const text = "আমি বাংলায় গান গাই";
const tagged = tagText(text);
console.log(tagged);
// Output: [
//   { word: "আমি", tag: UniversalPOSTag.PRON },
//   { word: "বাংলায়", tag: UniversalPOSTag.ADP },
//   { word: "গান", tag: UniversalPOSTag.NOUN },
//   { word: "গাই", tag: UniversalPOSTag.VERB }
// ]
```
