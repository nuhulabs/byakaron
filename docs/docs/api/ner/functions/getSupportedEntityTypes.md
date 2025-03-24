# getSupportedEntityTypes()

```ts
function getSupportedEntityTypes(): EntityType[];
```

Defined in: [index.ts:107](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/ner/src/index.ts#L107)

Retrieves all supported entity types.

## Returns

[`EntityType`](../enumerations/EntityType.md)[]

Array of all supported entity types

## Example

```ts
const types = getSupportedEntityTypes();
// Returns: [EntityType.PERSON, EntityType.ORGANIZATION, ...]
```
