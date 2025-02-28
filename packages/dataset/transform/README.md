# Wiki XML Parser

This module provides functionality to parse large Wikipedia XML dump files efficiently using streaming.

## Features

- Streams the XML file instead of loading it entirely into memory
- Uses SAX parser for efficient XML parsing
- Extracts key information from Wikipedia pages
- Outputs the parsed data as JSON

## Usage

To parse the Wikipedia XML dump file:

```bash
# From the packages/dataset directory
bun wiki-transform
```

This will:
1. Read the XML file from `packages/dataset/assets/1_bnwiki-latest-pages-articles.xml`
2. Parse the first 10 pages from the XML file
3. Save the parsed data to `packages/dataset/output/wiki-pages.json`

## Structure

- `parseWikiXml.ts` - The main parser that handles the XML streaming and parsing
- `wikiTransform.ts` - Entry point script that runs the parser

## Output Format

The output JSON file contains an array of Wikipedia page objects with the following structure:

```json
[
  {
    "title": "Page Title",
    "id": "12345",
    "ns": "0",
    "revision": {
      "id": "67890",
      "timestamp": "2023-01-01T00:00:00Z",
      "contributor": {
        "username": "Username",
        "id": "54321"
      },
      "text": "Page content..."
    }
  },
  ...
]
```

## Customization

To parse more than 10 pages, modify the `pageCount` check in the `parseWikiXml.ts` file. 