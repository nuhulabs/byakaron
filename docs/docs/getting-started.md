---
sidebar_position: 2
---

# Getting Started

## Installation

```bash
bun add @bntk/tokenization
# or
npm install @bntk/tokenization
```

## Usage

```ts
import * as tokenization from "@bntk/tokenization";

const tokens = tokenization.tokenizeWords(
  "আমি বাংলা লেখার জন্য টুলিটক ব্যবহার করছি",
);

console.log(tokens);
```
