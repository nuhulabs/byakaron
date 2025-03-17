# @bntk/dataset

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
import { transformWikiXmlToJsonl } from "@bntk/dataset/transform-sax";

await transformWikiXmlToJsonl({
  inputFile: "./assets/enwiki-latest-pages-articles.xml",
  outputFile: "./output/wiki.jsonl",
  maxPages: 10000, // Use Infinity to process all pages
  batchSize: 500,
  verbose: true,
});
```

For backward compatibility, the original function name is still available:

```typescript
import { transformWikiXmlToJson } from "@bntk/dataset/transform-sax";

// This now outputs JSONL format
await transformWikiXmlToJson({
  inputFile: "./assets/enwiki-latest-pages-articles.xml",
  outputFile: "./output/wiki.jsonl",
  maxPages: 10000,
  batchSize: 500,
  verbose: true,
});
```

# Dataset Package

This package provides utilities for managing and processing datasets, with a focus on text data processing.

## State Management

The `state.ts` module provides a robust state management system for tracking the progress of dataset processing tasks. It allows for resumable processing of large datasets by maintaining the state of various processing steps.

### Key Features

- **Persistent State**: State is saved to a JSON file, allowing processes to be resumed after interruption
- **Progress Tracking**: Track progress of multiple processing steps for multiple data sources
- **Resumable Processing**: Automatically detect and resume interrupted processing
- **Progress Visualization**: Display progress bars and estimated completion times
- **Generic Implementation**: Built on a generic state manager that can be extended for different use cases

### Main Components

#### Generic State Manager

The `GenericStateManager<T>` class provides a base implementation for state management:

```typescript
class GenericStateManager<T> {
  constructor(stateFilePath: string, defaultState: T);
  getState(): T;
  saveState(): void;
  updateState(updater: (state: T) => void): void;
}
```

#### Dataset State Manager

The `StateManager` class extends the generic state manager for dataset processing:

```typescript
class StateManager extends GenericStateManager<ProcessingState> {
  constructor(stateFilePath?: string, assetPath?: string);
  getSourceState(sourceId: string | number): SourceState;
  resetSourceState(sourceId: string | number, type: ProcessingStepType): void;
  updateSourceState(
    sourceId: string | number,
    type: ProcessingStepType,
    updates: StepUpdates,
  ): void;
  ensureSourceDir(sourceId: string | number): string;
  getSourceFilePaths(sourceId: string | number): {
    /* file paths */
  };
  isStepCompleted(sourceId: string | number, type: ProcessingStepType): boolean;
  shouldProcessFile(
    sourceId: string | number,
    type: ProcessingStepType,
  ): {
    /* result */
  };
  displayOverallProgress(
    sources: Array<{ id: string | number; name: string }>,
    final?: boolean,
  ): void;
}
```

#### State Structure

The state is organized by data sources and processing steps:

```typescript
interface ProcessingState {
  sources: {
    [sourceId: string | number]: {
      sentences: SentencesStep;
      words: WordsStep;
      distinctWords: DistinctWordsStep;
      distinctWordPairs: DistinctWordPairsStep;
    };
  };
}
```

Each processing step has its own interface that extends either `LineBasedStep` or `ByteBasedStep`, which both extend `BaseProcessingStep`:

```typescript
interface BaseProcessingStep {
  lastUpdated: string;
  completed: boolean;
}

interface LineBasedStep extends BaseProcessingStep {
  totalLines?: number;
  processedLines: number;
}

interface ByteBasedStep extends BaseProcessingStep {
  totalBytes?: number;
  processedBytes: number;
}
```

### Usage Examples

#### Using the StateManager Class

```typescript
import { StateManager } from "./state";

// Create a state manager instance
const stateManager = new StateManager();

// Get the current state
const state = stateManager.getState();

// Get or initialize state for a source
const sourceState = stateManager.getSourceState("source1");

// Update state for a specific processing step
stateManager.updateSourceState("source1", "sentences", {
  processedLines: 1000,
  totalSentencesProcessed: 5000,
});

// Check if a processing step is completed
const isCompleted = stateManager.isStepCompleted("source1", "sentences");

// Display overall progress
stateManager.displayOverallProgress([
  { id: "source1", name: "Wikipedia" },
  { id: "source2", name: "Books" },
]);
```

#### Using the Singleton Instance

For convenience, a singleton instance of `StateManager` is exported as `stateManager`, along with legacy functions that use this singleton:

```typescript
import { stateManager, updateState, displayOverallProgress } from "./state";

// Using the singleton instance directly
stateManager.updateSourceState("source1", "sentences", {
  processedLines: 1000,
  totalSentencesProcessed: 5000,
});

// Using legacy functions (these use the singleton internally)
const state = getState();
updateState(state, "source1", "sentences", {
  processedLines: 1000,
  totalSentencesProcessed: 5000,
});
displayOverallProgress(sources, state);
```

#### Creating a Custom State Manager

You can create your own state manager by extending `GenericStateManager`:

```typescript
import { GenericStateManager } from "./state";

interface MyState {
  counter: number;
  lastUpdated: string;
}

class MyStateManager extends GenericStateManager<MyState> {
  constructor() {
    super("./my-state.json", {
      counter: 0,
      lastUpdated: new Date().toISOString(),
    });
  }

  incrementCounter(amount: number = 1): void {
    this.updateState((state) => {
      state.counter += amount;
      state.lastUpdated = new Date().toISOString();
    });
  }
}

const myStateManager = new MyStateManager();
myStateManager.incrementCounter(5);
console.log(myStateManager.getState().counter); // 5
```

## Constants

The `constant.ts` module defines constants used throughout the dataset package:

- File paths for various data files
- Processing batch sizes
- File name patterns

## Usage Example

```typescript
import { getState, updateState, displayOverallProgress } from "./state";
import { prisma } from "@bntk/db";

async function processDatasets() {
  // Load current state
  const state = getState();

  // Get data sources
  const sources = await prisma.datasources.findMany();

  // Display initial progress
  displayOverallProgress(sources, state);

  // Process each source
  for (const source of sources) {
    // Update state as processing progresses
    updateState(state, source.id, "sentences", {
      processedLines: 1000,
      totalSentencesProcessed: 5000,
    });
  }

  // Display final progress
  displayOverallProgress(sources, state, true);
}
```

## File Structure

- `state.ts`: State management utilities
- `constant.ts`: Constants used throughout the package
- `transform/`: Data transformation utilities
  - `transform.ts`: Main transformation logic
  - `wiki-jsonl-to-std.ts`: Convert Wiki JSONL to standard format
  - `wiki-xml-to-jsonl.ts`: Convert Wiki XML to JSONL format

## References

- https://en.wikipedia.org/wiki/Extract,_transform,_load
