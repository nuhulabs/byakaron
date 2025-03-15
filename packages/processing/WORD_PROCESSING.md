# Word Processing

This module processes sentences from the database and extracts words and word pairs for language modeling.

## How it works

The process:

1. Reads sentences from the `sentences` table in batches
2. Processes each sentence in TypeScript to extract words
3. Performs bulk inserts of unique words into the `words` table
4. Creates word pairs and performs bulk upserts into the `word_groups` table
5. Increments the occurrence count for existing word pairs

## Implementation Details

The implementation uses:

- `pg` library for direct PostgreSQL connections
- Temporary tables for efficient bulk operations
- Batch processing to handle large datasets
- In-memory deduplication of words and word pairs
- Progress bar to track processing status

## Usage

To run the word processing:

```bash
# Install dependencies
bun install

# Run the word processing script
bun process-words
```

You can also import the functions in your code:

```typescript
import { processSentencesToWords } from '@bnkt/processing/word';

// Process sentences with a batch size of 1000
await processSentencesToWords(1000);
```

## Performance Considerations

- The process runs in batches to avoid memory issues with large datasets
- Bulk operations are used for better performance compared to individual inserts/updates
- Temporary tables are used for staging data before final insertion
- A unique constraint is added to the `word_groups` table for efficient upserts
- The batch size can be adjusted based on your database performance

## Customization

You can modify the word extraction logic in the `tokenizeSentence` function:

- The current implementation uses a simple regex cleanup and space-based tokenization
- You can enhance this with more sophisticated NLP tokenization if needed
- The weight calculation can be adjusted based on your specific requirements 