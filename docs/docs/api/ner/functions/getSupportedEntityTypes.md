# getSupportedEntityTypes()

```ts
function getSupportedEntityTypes(): EntityType[];
```

Defined in: [index.ts:107](https://github.com/nurulhudaapon/bntk/blob/3b9fe22b211144284ee58f4d31328c8e4ae31d1e/packages/core/ner/src/index.ts#L107)

Retrieves all supported entity types.

## Returns

[`EntityType`](../enumerations/EntityType.md)[]

Array of all supported entity types

## Example

```ts
const types = getSupportedEntityTypes();
// Returns: [EntityType.PERSON, EntityType.ORGANIZATION, ...]
```
