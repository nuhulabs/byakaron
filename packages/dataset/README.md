# @bngc/dataset

Extract data from sources and save to persistent storage to be transformed and loaded into a data warehouse.

## SAX Transformer

The SAX transformer provides an efficient way to convert large Wiki XML dumps to JSONL (JSON Lines) format.

### Usage

```bash
bun packages/dataset/transform-sax.ts <input-xml-file> <output-jsonl-file> [max-pages] [batch-size]
```

### Parameters

- `input-xml-file`: Path to the input XML file
- `output-jsonl-file`: Path to the output JSONL file
- `max-pages` (optional): Maximum number of pages to process (default: Infinity)
  - You can pass a number or the string "infinity" or "inf" to process all pages
- `batch-size` (optional): Number of pages to process before logging progress (default: 1000)

### Examples

Process the first 10,000 pages:
```bash
bun packages/dataset/transform-sax.ts ./assets/enwiki-latest-pages-articles.xml ./output/wiki.jsonl 10000 500
```

Process all pages (equivalent to omitting the max-pages parameter):
```bash
bun packages/dataset/transform-sax.ts ./assets/enwiki-latest-pages-articles.xml ./output/wiki.jsonl infinity 500
```

### JSONL Format

The output is in JSONL (JSON Lines) format, where each line is a valid JSON object representing a single wiki page. This format is more efficient for streaming and processing large datasets, as it allows for line-by-line processing without loading the entire file into memory.

### Programmatic Usage

You can also use the transformer programmatically:

```typescript
import { transformWikiXmlToJsonl } from '@bngc/dataset/transform-sax';

await transformWikiXmlToJsonl({
  inputFile: './assets/enwiki-latest-pages-articles.xml',
  outputFile: './output/wiki.jsonl',
  maxPages: 10000,  // Use Infinity to process all pages
  batchSize: 500,
  verbose: true
});
```

For backward compatibility, the original function name is still available:

```typescript
import { transformWikiXmlToJson } from '@bngc/dataset/transform-sax';

// This now outputs JSONL format
await transformWikiXmlToJson({
  inputFile: './assets/enwiki-latest-pages-articles.xml',
  outputFile: './output/wiki.jsonl',
  maxPages: 10000,
  batchSize: 500,
  verbose: true
});
```
