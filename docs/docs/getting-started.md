---
sidebar_position: 2
---

# Getting Started

#### 🧰 Learn about individual [Toolkits](./category/toolkits)

Here's a quick start guide to help you get started with the Bangla Toolkit (BNTK).

#### Installation

Install the required packages for Bengali natural language processing:

```bash npm2yarn
npm install @bntk/tokenization @bntk/stemming @bntk/pos @bntk/ner @bntk/transliteration
```

#### Example Usage

```typescript
import * as ner from "@bntk/ner";
import * as pos from "@bntk/pos";
import * as stemming from "@bntk/stemming";
import * as tokenization from "@bntk/tokenization";
import * as transliteration from "@bntk/transliteration";

const contents = `আমি বাংলা লেখার জন্য টুলিটক ব্যবহার করছি। আমার বন্ধু রহিম ঢাকায় থাকেন।`;

// ==== Tokenization ====
const sentences = tokenization.tokenizeSentences(contents);
console.log(sentences);
// ['আমি বাংলা লেখার জন্য টুলিটক ব্যবহার করছি', 'আমার বন্ধু রহিম ঢাকায় থাকেন']

const words = tokenization.tokenizeWords(sentences[0]);
console.log(words);
// ['আমি', 'বাংলা', 'লেখার', 'জন্য', 'টুলিটক', 'ব্যবহার', 'করছি']

// ==== Stemming ====
const stemmedWords = stemming.stemWords(words);
console.log(stemmedWords);
// ['আমি', 'বাংলা', 'লেখার', 'জন্য', 'টুলিটক', 'ব্যবহার', 'করছি']

// ==== POS ====
const taggedWords = pos.tagWords(stemmedWords);
console.log(taggedWords);
// ['আমি/PRON', 'বাংলা/NOUN', 'লেখার/NOUN', 'জন্য/ADP', 'টুলিটক/NOUN', 'ব্যবহার/VERB', 'করছি/VERB']

// ==== NER ====
const entities = ner.extractEntities(sentences[1]);
console.log(entities);
// [{type: 'PRONOUN', value: 'আমার', start: 0, end: 4}, {...}]

// ==== Transliteration ====
const transliterated = transliteration.transliterate("amar name apon.");
console.log(transliterated);
// 'আমার নাম আপন।'
```

### 📚 See [API Reference](/docs/api)
