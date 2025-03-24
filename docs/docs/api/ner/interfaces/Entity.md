# Entity

Defined in: [index.ts:10](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/ner/src/index.ts#L10)

Represents a named entity found in text with its position and classification details.

## Properties

| Property                             | Type                                          | Description                                  | Defined in                                                                                                                            |
| ------------------------------------ | --------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| <a id="confidence"></a> `confidence` | `number`                                      | Confidence score of the classification (0-1) | [index.ts:15](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/ner/src/index.ts#L15) |
| <a id="end"></a> `end`               | `number`                                      | Ending position of the entity in the text    | [index.ts:14](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/ner/src/index.ts#L14) |
| <a id="start"></a> `start`           | `number`                                      | Starting position of the entity in the text  | [index.ts:13](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/ner/src/index.ts#L13) |
| <a id="text"></a> `text`             | `string`                                      | The actual text of the entity                | [index.ts:11](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/ner/src/index.ts#L11) |
| <a id="type"></a> `type`             | [`EntityType`](../enumerations/EntityType.md) | The classification type of the entity        | [index.ts:12](https://github.com/nurulhudaapon/bntk/blob/314d9b2ac599759411d348b48ba4fdc0d09954c0/packages/core/ner/src/index.ts#L12) |
