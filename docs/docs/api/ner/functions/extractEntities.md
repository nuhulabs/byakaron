# extractEntities()

```ts
function extractEntities(text): Entity[];
```

Defined in: [index.ts:41](https://github.com/nurulhudaapon/bntk/blob/3b9fe22b211144284ee58f4d31328c8e4ae31d1e/packages/core/ner/src/index.ts#L41)

Extracts named entities from input text.

## Parameters

| Parameter | Type     | Description               |
| --------- | -------- | ------------------------- |
| `text`    | `string` | The input text to analyze |

## Returns

[`Entity`](../interfaces/Entity.md)[]

Array of detected entities with their positions and classifications

## Example

```ts
const entities = extractEntities("John Doe works at Apple Inc.");
// Returns: [{text: "John Doe", type: "PERSON", start: 0, end: 8, confidence: 0.95}]
```
