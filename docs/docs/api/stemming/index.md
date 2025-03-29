# 📦 @bntk/stemming

## removePrefix()

```ts
function removePrefix(word): string;
```

Defined in: [stemming.ts:26](https://github.com/nurulhudaapon/bntk/blob/a800a88ba2a08067633bfe63793a7c8b86a8a486/packages/core/stemming/src/stemming.ts#L26)

Removes matching prefix from the beginning of a word

### Parameters

| Parameter | Type     | Description                    |
| --------- | -------- | ------------------------------ |
| `word`    | `string` | The word to remove prefix from |

### Returns

`string`

The word with prefix removed if matched, otherwise original word

---

## removeSuffix()

```ts
function removeSuffix(word): string;
```

Defined in: [stemming.ts:46](https://github.com/nurulhudaapon/bntk/blob/a800a88ba2a08067633bfe63793a7c8b86a8a486/packages/core/stemming/src/stemming.ts#L46)

Removes matching suffix from the end of a word

### Parameters

| Parameter | Type     | Description                    |
| --------- | -------- | ------------------------------ |
| `word`    | `string` | The word to remove suffix from |

### Returns

`string`

The word with suffix removed if matched, otherwise original word

---

## stemWord()

```ts
function stemWord(word): string;
```

Defined in: [stemming.ts:65](https://github.com/nurulhudaapon/bntk/blob/a800a88ba2a08067633bfe63793a7c8b86a8a486/packages/core/stemming/src/stemming.ts#L65)

Stems a Bangla word by removing prefixes and suffixes

### Parameters

| Parameter | Type     | Description      |
| --------- | -------- | ---------------- |
| `word`    | `string` | The word to stem |

### Returns

`string`

The stemmed word

---

## stemWords()

```ts
function stemWords(words): string[];
```

Defined in: [stemming.ts:84](https://github.com/nurulhudaapon/bntk/blob/a800a88ba2a08067633bfe63793a7c8b86a8a486/packages/core/stemming/src/stemming.ts#L84)

Stems an array of Bangla words

### Parameters

| Parameter | Type       | Description            |
| --------- | ---------- | ---------------------- |
| `words`   | `string`[] | Array of words to stem |

### Returns

`string`[]

Array of stemmed words
