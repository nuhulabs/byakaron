# getPOSTagFrequencies()

```ts
function getPOSTagFrequencies(taggedWords): Map<UniversalPOSTag, number>;
```

Defined in: [index.ts:196](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/pos/src/index.ts#L196)

Gets the most common POS tags in a sequence of tagged words

## Parameters

| Parameter     | Type                                          | Description           |
| ------------- | --------------------------------------------- | --------------------- |
| `taggedWords` | [`TaggedWord`](../interfaces/TaggedWord.md)[] | Array of tagged words |

## Returns

`Map`\<[`UniversalPOSTag`](../enumerations/UniversalPOSTag.md), `number`\>

Map of POS tags to their frequencies

## Description

This function analyzes a sequence of tagged words and returns
a map showing how many times each POS tag appears.

## Example

```typescript
const tagged = [
  { word: "আমি", tag: UniversalPOSTag.PRON },
  { word: "বাংলায়", tag: UniversalPOSTag.ADP },
  { word: "গান", tag: UniversalPOSTag.NOUN },
  { word: "গাই", tag: UniversalPOSTag.VERB },
];
const frequencies = getPOSTagFrequencies(tagged);
console.log(frequencies);
// Output: Map(4) {
//   UniversalPOSTag.PRON => 1,
//   UniversalPOSTag.ADP => 1,
//   UniversalPOSTag.NOUN => 1,
//   UniversalPOSTag.VERB => 1
// }
```
