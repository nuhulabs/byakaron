# classifyEntity()

```ts
function classifyEntity(text): EntityType;
```

Defined in: [index.ts:68](https://github.com/nurulhudaapon/bntk/blob/3b9fe22b211144284ee58f4d31328c8e4ae31d1e/packages/core/ner/src/index.ts#L68)

Classifies a single text segment into an entity type.

## Parameters

| Parameter | Type     | Description          |
| --------- | -------- | -------------------- |
| `text`    | `string` | The text to classify |

## Returns

[`EntityType`](../enumerations/EntityType.md)

The predicted entity type

## Example

```ts
const type = classifyEntity("John Doe");
// Returns: EntityType.PERSON
```
