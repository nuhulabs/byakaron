---
sidebar_position: 2
---

# Getting Started

### Installation

Install the required packages for Bengali natural language processing:

```bash npm2yarn
npm install @bntk/tokenization @bntk/stemming @bntk/pos @bntk/ner
```

### Usage

```typescript
// Import the required modules
import * as ner from "@bntk/ner";
import * as pos from "@bntk/pos";
import * as stemming from "@bntk/stemming";
import * as tokenization from "@bntk/tokenization";

// Example Bengali text
const contents = `
আমি বাংলা লেখার জন্য টুলিটক ব্যবহার করছি। আমার বন্ধু রহিম ঢাকায় থাকেন।
`;

// Step 1: Split text into sentences
const sentences = tokenization.tokenizeSentences(contents);
console.log(sentences);
// ['আমি বাংলা লেখার জন্য টুলিটক ব্যবহার করছি', 'আমার বন্ধু রহিম ঢাকায় থাকেন']

// Step 2: Split first sentence into words
const words = tokenization.tokenizeWords(sentences[0]);
console.log(words);
// ['আমি', 'বাংলা', 'লেখার', 'জন্য', 'টুলিটক', 'ব্যবহার', 'করছি']

// Step 3: Apply stemming to words
const stemmedWords = stemming.stemWords(words);
console.log(stemmedWords);
// ['আমি', 'বাংলা', 'লেখার', 'জন্য', 'টুলিটক', 'ব্যবহার', 'করছি']

// Step 4: Perform part-of-speech tagging
const taggedWords = pos.tagWords(stemmedWords);
console.log(taggedWords);
// ['আমি/PRON', 'বাংলা/NOUN', 'লেখার/NOUN', 'জন্য/ADP', 'টুলিটক/NOUN', 'ব্যবহার/VERB', 'করছি/VERB']

// Step 5: Extract named entities
const entities = ner.extractEntities(sentences[1]);
console.log(entities);
// [
//   {
//     type: 'PRONOUN',
//     value: 'আমার',
//     start: 0,
//     end: 4,
//   },
//   {
//     type: 'NOUN',
//     value: 'বন্ধু',
//     start: 6,
//     end: 10,
//   },
//   {
//     type: 'PERSON',
//     value: 'রহিম',
//     start: 11,
//     end: 16,
//   },
//   {
//     type: 'LOCATION',
//     value: 'ঢাকায়',
//     start: 17,
//     end: 22,
//   },
//   {
//     type: 'VERB',
//     value: 'থাকেন',
//     start: 23,
//     end: 28,
//   }
// ]
```

### API Reference

See the [comprehensive documentation](/docs/api) for detailed API reference and examples.
