# batchExtractEntities()

```ts
function batchExtractEntities(texts): Entity[][];
```

Defined in: [index.ts:96](https://github.com/nurulhudaapon/bntk/blob/3b9fe22b211144284ee58f4d31328c8e4ae31d1e/packages/core/ner/src/index.ts#L96)

Processes multiple texts for entity extraction in batch.

## Parameters

| Parameter | Type       | Description               |
| --------- | ---------- | ------------------------- |
| `texts`   | `string`[] | Array of texts to process |

## Returns

[`Entity`](../interfaces/Entity.md)[][]

Array of entity arrays for each input text

## Example

```ts
const results = batchExtractEntities(["John Doe", "New York"]);
// Returns: [[{text: "John Doe", ...}], [{text: "New York", ...}]]
```
