# 📦 @bntk/pos

## UniversalPOSTag

Defined in: [index.ts:11](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L11)

Universal POS tags based on Universal Dependencies (UD) v2 specification
Source: https://universaldependencies.org/u/pos/

### Enumeration Members

| Enumeration Member         | Value     | Description                                                                                                                               | Defined in                                                                                                                            |
| -------------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| <a id="adj"></a> `ADJ`     | `"ADJ"`   | Adjectives are words that typically modify nouns **Example** `বড়/boro, সুন্দর/sundor, নতুন/notun`                                        | [index.ts:14](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L14) |
| <a id="adp"></a> `ADP`     | `"ADP"`   | Adpositions are prepositions and postpositions **Example** `মধ্যে/moddhe, থেকে/theke, উপরে/upore`                                         | [index.ts:17](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L17) |
| <a id="adv"></a> `ADV`     | `"ADV"`   | Adverbs are words that typically modify verbs, adjectives or other adverbs **Example** `খুব/khub, ধীরে/dhire, ভালোভাবে/bhalobhabe`        | [index.ts:20](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L20) |
| <a id="aux"></a> `AUX`     | `"AUX"`   | Auxiliary verbs are used to form tenses, moods, etc. **Example** `আছে/ache, হয়/hoi, হবে/hobe`                                            | [index.ts:23](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L23) |
| <a id="cconj"></a> `CCONJ` | `"CCONJ"` | Coordinating conjunctions connect words, phrases, clauses of equal status **Example** `এবং/ebong, কিন্তু/kintu, অথবা/othoba`              | [index.ts:26](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L26) |
| <a id="det"></a> `DET`     | `"DET"`   | Determiners are words that modify nouns or noun phrases **Example** `এই/ei, সেই/sei, কোন/kon`                                             | [index.ts:29](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L29) |
| <a id="intj"></a> `INTJ`   | `"INTJ"`  | Interjections are exclamatory words **Example** `ওহ/oh, বাহ/bah, হায়/hay`                                                                | [index.ts:32](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L32) |
| <a id="noun"></a> `NOUN`   | `"NOUN"`  | Nouns are words denoting all physical objects and materials **Example** `বই/boi, মানুষ/manush, বাড়ি/bari`                                | [index.ts:35](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L35) |
| <a id="num"></a> `NUM`     | `"NUM"`   | Numerals represent numbers, quantities, etc. **Example** `এক/ek, দুই/dui, প্রথম/prothom`                                                  | [index.ts:38](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L38) |
| <a id="part"></a> `PART`   | `"PART"`  | Particles are function words that must be associated with another word **Example** `না/na, তো/to, কি/ki`                                  | [index.ts:41](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L41) |
| <a id="pron"></a> `PRON`   | `"PRON"`  | Pronouns substitute for nouns or noun phrases **Example** `আমি/ami, তুমি/tumi, সে/se`                                                     | [index.ts:44](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L44) |
| <a id="propn"></a> `PROPN` | `"PROPN"` | Proper nouns are names of specific persons, places, organizations **Example** `ঢাকা/dhaka, রবীন্দ্রনাথ/robindronath, বাংলাদেশ/bangladesh` | [index.ts:47](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L47) |
| <a id="punct"></a> `PUNCT` | `"PUNCT"` | Punctuation marks **Example** `।, ?, !, ,`                                                                                                | [index.ts:50](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L50) |
| <a id="sconj"></a> `SCONJ` | `"SCONJ"` | Subordinating conjunctions link dependent clauses to independent ones **Example** `যদি/jodi, কারণ/karon, যখন/jokhon`                      | [index.ts:53](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L53) |
| <a id="sym"></a> `SYM`     | `"SYM"`   | Symbols represent currency, math operators, etc. **Example** `৳, +, =`                                                                    | [index.ts:56](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L56) |
| <a id="verb"></a> `VERB`   | `"VERB"`  | Verbs denote actions and processes **Example** `যাই/jai, খাই/khai, পড়ি/pori`                                                             | [index.ts:59](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L59) |
| <a id="x"></a> `X`         | `"X"`     | Other words that don't fit into above categories **Example** `ইত্যাদি/ittyadi, প্রভৃতি/probhriti`                                         | [index.ts:62](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L62) |

---

## TaggedWord

Defined in: [index.ts:68](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L68)

Represents a word with its POS tag and additional linguistic features

### Properties

| Property                          | Type                                  | Description                                                 | Defined in                                                                                                                            |
| --------------------------------- | ------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| <a id="features"></a> `features?` | `Record`\<`string`, `string`\>        | Additional linguistic features (e.g., gender, number, case) | [index.ts:74](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L74) |
| <a id="tag"></a> `tag`            | [`UniversalPOSTag`](#universalpostag) | The POS tag for the word                                    | [index.ts:72](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L72) |
| <a id="word"></a> `word`          | `string`                              | The original word                                           | [index.ts:70](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L70) |

---

## getPOSTagFrequencies()

```ts
function getPOSTagFrequencies(taggedWords): Map<UniversalPOSTag, number>;
```

Defined in: [index.ts:196](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L196)

Gets the most common POS tags in a sequence of tagged words

### Parameters

| Parameter     | Type                          | Description           |
| ------------- | ----------------------------- | --------------------- |
| `taggedWords` | [`TaggedWord`](#taggedword)[] | Array of tagged words |

### Returns

`Map`\<[`UniversalPOSTag`](#universalpostag), `number`\>

Map of POS tags to their frequencies

### Description

This function analyzes a sequence of tagged words and returns
a map showing how many times each POS tag appears.

### Example

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

---

## tagText()

```ts
function tagText(text): TaggedWord[];
```

Defined in: [index.ts:162](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L162)

Tags a Bangla text string with parts of speech

### Parameters

| Parameter | Type     | Description            |
| --------- | -------- | ---------------------- |
| `text`    | `string` | The Bangla text to tag |

### Returns

[`TaggedWord`](#taggedword)[]

Array of words with their POS tags and features

### Description

This function first tokenizes the input text into words and then
performs POS tagging on the resulting word sequence.

### Example

```typescript
const text = "আমি বাংলায় গান গাই";
const tagged = tagText(text);
console.log(tagged);
// Output: [
//   { word: "আমি", tag: UniversalPOSTag.PRON },
//   { word: "বাংলায়", tag: UniversalPOSTag.ADP },
//   { word: "গান", tag: UniversalPOSTag.NOUN },
//   { word: "গাই", tag: UniversalPOSTag.VERB }
// ]
```

---

## tagWord()

```ts
function tagWord(word): TaggedWord;
```

Defined in: [index.ts:102](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L102)

Tags a single Bangla word with its part of speech

### Parameters

| Parameter | Type     | Description            |
| --------- | -------- | ---------------------- |
| `word`    | `string` | The Bangla word to tag |

### Returns

[`TaggedWord`](#taggedword)

The word with its POS tag and features

### Description

This function performs POS tagging for a single Bangla word.
It uses a combination of rules and dictionary lookup to determine
the most likely POS tag for the given word.

### Examples

```typescript
const result = tagWord("বাংলা");
console.log(result);
// Output: { word: "বাংলা", tag: UniversalPOSTag.NOUN }
```

```typescript
const result = tagWord("সুন্দর");
console.log(result);
// Output: { word: "সুন্দর", tag: UniversalPOSTag.ADJ }
```

---

## tagWords()

```ts
function tagWords(words): TaggedWord[];
```

Defined in: [index.ts:134](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/pos/src/index.ts#L134)

Tags a sequence of Bangla words with their parts of speech

### Parameters

| Parameter | Type       | Description                  |
| --------- | ---------- | ---------------------------- |
| `words`   | `string`[] | Array of Bangla words to tag |

### Returns

[`TaggedWord`](#taggedword)[]

Array of words with their POS tags and features

### Description

This function performs POS tagging for a sequence of Bangla words.
It takes into account the context of surrounding words to improve
tagging accuracy.

### Example

```typescript
const words = ["আমি", "বাংলায়", "গান", "গাই"];
const tagged = tagWords(words);
console.log(tagged);
// Output: [
//   { word: "আমি", tag: UniversalPOSTag.PRON },
//   { word: "বাংলায়", tag: UniversalPOSTag.ADP },
//   { word: "গান", tag: UniversalPOSTag.NOUN },
//   { word: "গাই", tag: UniversalPOSTag.VERB }
// ]
```
