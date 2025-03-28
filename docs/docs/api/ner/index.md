# 📦 @bntk/ner

## EntityType

Defined in: [index.ts:22](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L22)

Enumeration of supported named entity types.

### Enumeration Members

| Enumeration Member                       | Value            | Defined in                                                                                                                            |
| ---------------------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| <a id="date"></a> `DATE`                 | `"DATE"`         | [index.ts:26](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L26) |
| <a id="location"></a> `LOCATION`         | `"LOCATION"`     | [index.ts:25](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L25) |
| <a id="money"></a> `MONEY`               | `"MONEY"`        | [index.ts:27](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L27) |
| <a id="organization"></a> `ORGANIZATION` | `"ORGANIZATION"` | [index.ts:24](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L24) |
| <a id="percent"></a> `PERCENT`           | `"PERCENT"`      | [index.ts:28](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L28) |
| <a id="person"></a> `PERSON`             | `"PERSON"`       | [index.ts:23](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L23) |
| <a id="time"></a> `TIME`                 | `"TIME"`         | [index.ts:29](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L29) |
| <a id="unknown"></a> `UNKNOWN`           | `"UNKNOWN"`      | [index.ts:30](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L30) |

---

## Entity

Defined in: [index.ts:10](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L10)

Represents a named entity found in text with its position and classification details.

### Properties

| Property                             | Type                        | Description                                  | Defined in                                                                                                                            |
| ------------------------------------ | --------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| <a id="confidence"></a> `confidence` | `number`                    | Confidence score of the classification (0-1) | [index.ts:15](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L15) |
| <a id="end"></a> `end`               | `number`                    | Ending position of the entity in the text    | [index.ts:14](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L14) |
| <a id="start"></a> `start`           | `number`                    | Starting position of the entity in the text  | [index.ts:13](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L13) |
| <a id="text"></a> `text`             | `string`                    | The actual text of the entity                | [index.ts:11](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L11) |
| <a id="type"></a> `type`             | [`EntityType`](#entitytype) | The classification type of the entity        | [index.ts:12](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L12) |

---

## batchExtractEntities()

```ts
function batchExtractEntities(texts): Entity[][];
```

Defined in: [index.ts:96](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L96)

Processes multiple texts for entity extraction in batch.

### Parameters

| Parameter | Type       | Description               |
| --------- | ---------- | ------------------------- |
| `texts`   | `string`[] | Array of texts to process |

### Returns

[`Entity`](#entity)[][]

Array of entity arrays for each input text

### Example

```ts
const results = batchExtractEntities(["John Doe", "New York"]);
// Returns: [[{text: "John Doe", ...}], [{text: "New York", ...}]]
```

---

## classifyEntity()

```ts
function classifyEntity(text): EntityType;
```

Defined in: [index.ts:68](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L68)

Classifies a single text segment into an entity type.

### Parameters

| Parameter | Type     | Description          |
| --------- | -------- | -------------------- |
| `text`    | `string` | The text to classify |

### Returns

[`EntityType`](#entitytype)

The predicted entity type

### Example

```ts
const type = classifyEntity("John Doe");
// Returns: EntityType.PERSON
```

---

## extractEntities()

```ts
function extractEntities(text): Entity[];
```

Defined in: [index.ts:41](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L41)

Extracts named entities from input text.

### Parameters

| Parameter | Type     | Description               |
| --------- | -------- | ------------------------- |
| `text`    | `string` | The input text to analyze |

### Returns

[`Entity`](#entity)[]

Array of detected entities with their positions and classifications

### Example

```ts
const entities = extractEntities("John Doe works at Apple Inc.");
// Returns: [{text: "John Doe", type: "PERSON", start: 0, end: 8, confidence: 0.95}]
```

---

## getEntityConfidence()

```ts
function getEntityConfidence(text, entityType): number;
```

Defined in: [index.ts:81](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L81)

Calculates confidence score for entity classification.

### Parameters

| Parameter    | Type                        | Description              |
| ------------ | --------------------------- | ------------------------ |
| `text`       | `string`                    | The text to analyze      |
| `entityType` | [`EntityType`](#entitytype) | The entity type to check |

### Returns

`number`

Confidence score between 0 and 1

### Example

```ts
const confidence = getEntityConfidence("John Doe", EntityType.PERSON);
// Returns: 0.85
```

---

## getSupportedEntityTypes()

```ts
function getSupportedEntityTypes(): EntityType[];
```

Defined in: [index.ts:107](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/ner/src/index.ts#L107)

Retrieves all supported entity types.

### Returns

[`EntityType`](#entitytype)[]

Array of all supported entity types

### Example

```ts
const types = getSupportedEntityTypes();
// Returns: [EntityType.PERSON, EntityType.ORGANIZATION, ...]
```
