# batchExtractEntities()

```ts
function batchExtractEntities(texts): Entity[][];
```

Defined in: [index.ts:96](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/ner/src/index.ts#L96)

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
