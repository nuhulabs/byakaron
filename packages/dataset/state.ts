import { existsSync, readFileSync, writeFileSync, mkdirSync } from "fs";
import * as path from "path";
import {
  STATE_FILE_PATH,
  SENTENCES_FILE,
  WORDS_CSV_FILE,
  DISTINCT_WORDS_FILE,
  DISTINCT_WORD_PAIRS_FILE,
  ASSET_PATH,
} from "./constant";

// Define processing step types
export type ProcessingStepType =
  | "sentences"
  | "words"
  | "distinctWords"
  | "distinctWordPairs";

// Define base state interface for a processing step
export interface BaseProcessingStep {
  lastUpdated: string;
  completed: boolean;
}

// Define line-based processing step
export interface LineBasedStep extends BaseProcessingStep {
  totalLines?: number;
  processedLines: number;
}

// Define byte-based processing step
export interface ByteBasedStep extends BaseProcessingStep {
  totalBytes?: number;
  processedBytes: number;
}

// Define sentences processing step
export interface SentencesStep extends LineBasedStep {
  totalSentencesProcessed: number;
}

// Define words processing step
export interface WordsStep extends LineBasedStep {
  totalWordPairsProcessed: number;
}

// Define distinct words processing step
export interface DistinctWordsStep extends ByteBasedStep {
  uniqueWordsCount: number;
}

// Define distinct word pairs processing step
export interface DistinctWordPairsStep extends ByteBasedStep {
  uniquePairsCount: number;
}

// Define source state interface
export interface SourceState {
  sentences: SentencesStep;
  words: WordsStep;
  distinctWords: DistinctWordsStep;
  distinctWordPairs: DistinctWordPairsStep;
}

// Define state interface
export interface ProcessingState {
  sources: {
    [sourceId: string | number]: SourceState;
  };
}

// Type for sentence updates
export type SentenceUpdates = Partial<SentencesStep>;

// Type for word updates
export type WordUpdates = Partial<WordsStep>;

// Type for distinct words updates
export type DistinctWordsUpdates = Partial<DistinctWordsStep>;

// Type for distinct word pairs updates
export type DistinctWordPairsUpdates = Partial<DistinctWordPairsStep>;

// Type for any step updates
export type StepUpdates =
  | SentenceUpdates
  | WordUpdates
  | DistinctWordsUpdates
  | DistinctWordPairsUpdates;

/**
 * Generic state manager for tracking processing progress
 */
export class GenericStateManager<T> {
  protected state: T;
  protected stateFilePath: string;

  /**
   * Create a new GenericStateManager instance
   * @param stateFilePath Path to the state file
   * @param defaultState Default state to use if no state file exists
   */
  constructor(stateFilePath: string, defaultState: T) {
    this.stateFilePath = stateFilePath;
    this.state = this.loadState(defaultState);
  }

  /**
   * Get the current state
   */
  public getState(): T {
    return this.state;
  }

  /**
   * Load state from file or initialize with default state
   */
  protected loadState(defaultState: T): T {
    try {
      if (existsSync(this.stateFilePath)) {
        const stateData = readFileSync(this.stateFilePath, "utf8");
        return JSON.parse(stateData);
      }
    } catch (error) {
      console.error("Error reading state file:", error);
    }

    // Return default state if file doesn't exist or has errors
    return JSON.parse(JSON.stringify(defaultState));
  }

  /**
   * Save state to file
   */
  public saveState(): void {
    try {
      writeFileSync(
        this.stateFilePath,
        JSON.stringify(this.state, null, 2),
        "utf8",
      );
    } catch (error) {
      console.error("Error saving state file:", error);
    }
  }

  /**
   * Update state
   * @param updater Function that updates the state
   */
  public updateState(updater: (state: T) => void): void {
    updater(this.state);
    this.saveState();
  }
}

/**
 * StateManager class for managing dataset processing state
 */
export class StateManager extends GenericStateManager<ProcessingState> {
  private assetPath: string;

  // Default empty state for a source
  private static EMPTY_SOURCE_STATE: SourceState = {
    sentences: {
      processedLines: 0,
      totalSentencesProcessed: 0,
      lastUpdated: new Date().toISOString(),
      completed: false,
    },
    words: {
      processedLines: 0,
      totalWordPairsProcessed: 0,
      lastUpdated: new Date().toISOString(),
      completed: false,
    },
    distinctWords: {
      processedBytes: 0,
      uniqueWordsCount: 0,
      lastUpdated: new Date().toISOString(),
      completed: false,
    },
    distinctWordPairs: {
      processedBytes: 0,
      uniquePairsCount: 0,
      lastUpdated: new Date().toISOString(),
      completed: false,
    },
  };

  /**
   * Create a new StateManager instance
   * @param stateFilePath Path to the state file
   * @param assetPath Path to the assets directory
   */
  constructor(
    stateFilePath: string = STATE_FILE_PATH,
    assetPath: string = ASSET_PATH,
  ) {
    super(stateFilePath, { sources: {} });
    this.assetPath = assetPath;
  }

  /**
   * Get source state or initialize if not exists
   * @param sourceId Source ID
   */
  public getSourceState(sourceId: string | number): SourceState {
    if (!this.state?.sources?.[sourceId]) {
      this.state.sources[sourceId] = JSON.parse(
        JSON.stringify(StateManager.EMPTY_SOURCE_STATE),
      );
      this.saveState();
    }
    return this.state.sources[sourceId];
  }

  /**
   * Reset source state for a specific processing type
   * @param sourceId Source ID
   * @param type Processing step type
   */
  public resetSourceState(
    sourceId: string | number,
    type: ProcessingStepType,
  ): void {
    if (this.state.sources[sourceId]) {
      const defaultState = StateManager.EMPTY_SOURCE_STATE[type];
      this.state.sources[sourceId][type] = JSON.parse(
        JSON.stringify(defaultState),
      );
      this.saveState();
    }
  }

  /**
   * Update state for a specific source and processing type
   * @param sourceId Source ID
   * @param type Processing step type
   * @param updates Updates to apply
   */
  public updateSourceState(
    sourceId: string | number,
    type: ProcessingStepType,
    updates: StepUpdates,
  ): void {
    const sourceState = this.getSourceState(sourceId);

    if (type === "sentences") {
      sourceState.sentences = {
        ...sourceState.sentences,
        ...(updates as SentenceUpdates),
        lastUpdated: new Date().toISOString(),
      };
    } else if (type === "words") {
      sourceState.words = {
        ...sourceState.words,
        ...(updates as WordUpdates),
        lastUpdated: new Date().toISOString(),
      };
    } else if (type === "distinctWords") {
      sourceState.distinctWords = {
        ...sourceState.distinctWords,
        ...(updates as DistinctWordsUpdates),
        lastUpdated: new Date().toISOString(),
      };
    } else if (type === "distinctWordPairs") {
      sourceState.distinctWordPairs = {
        ...sourceState.distinctWordPairs,
        ...(updates as DistinctWordPairsUpdates),
        lastUpdated: new Date().toISOString(),
      };
    }

    this.saveState();
  }

  /**
   * Ensure source directory exists
   * @param sourceId Source ID
   */
  public ensureSourceDir(sourceId: string | number): string {
    const sourceDirPath = path.join(this.assetPath, String(sourceId));
    if (!existsSync(sourceDirPath)) {
      mkdirSync(sourceDirPath, { recursive: true });
      console.log(`Created directory for source ${sourceId}: ${sourceDirPath}`);
    }
    return sourceDirPath;
  }

  /**
   * Get file paths for a specific source
   * @param sourceId Source ID
   */
  public getSourceFilePaths(sourceId: string | number): {
    sentencesFilePath: string;
    wordsFilePath: string;
    distinctWordsFilePath: string;
    distinctWordPairsFilePath: string;
  } {
    const sourceDirPath = this.ensureSourceDir(sourceId);

    return {
      sentencesFilePath: path.join(sourceDirPath, SENTENCES_FILE),
      wordsFilePath: path.join(sourceDirPath, WORDS_CSV_FILE),
      distinctWordsFilePath: path.join(sourceDirPath, DISTINCT_WORDS_FILE),
      distinctWordPairsFilePath: path.join(
        sourceDirPath,
        DISTINCT_WORD_PAIRS_FILE,
      ),
    };
  }

  /**
   * Check if a source has completed a specific processing step
   * @param sourceId Source ID
   * @param type Processing step type
   */
  public isStepCompleted(
    sourceId: string | number,
    type: ProcessingStepType,
  ): boolean {
    const sourceState = this.state.sources[sourceId];
    if (!sourceState) return false;

    return sourceState[type].completed;
  }

  /**
   * Check if a source file exists and should be processed
   * @param sourceId Source ID
   * @param type Processing step type
   */
  public shouldProcessFile(
    sourceId: string | number,
    type: ProcessingStepType,
  ): { shouldProcess: boolean; shouldResume: boolean; filePath: string } {
    const sourceState = this.getSourceState(sourceId);
    const filePaths = this.getSourceFilePaths(sourceId);

    let filePath = "";

    switch (type) {
      case "sentences":
        filePath = filePaths.sentencesFilePath;
        break;
      case "words":
        filePath = filePaths.wordsFilePath;
        break;
      case "distinctWords":
        filePath = filePaths.distinctWordsFilePath;
        break;
      case "distinctWordPairs":
        filePath = filePaths.distinctWordPairsFilePath;
        break;
    }

    // Check if file exists
    const fileExists = existsSync(filePath);

    // Get progress for this type
    let hasStarted = false;

    // Check if processing has started based on the type
    if (type === "sentences" || type === "words") {
      hasStarted = sourceState[type].processedLines > 0;
    } else if (type === "distinctWords" || type === "distinctWordPairs") {
      hasStarted = sourceState[type].processedBytes > 0;
    }

    // Reset state if output file doesn't exist but processing has started
    if (!fileExists && hasStarted) {
      console.log(
        `${type} file doesn't exist but state shows processing started. Resetting state for source ${sourceId}`,
      );
      this.resetSourceState(sourceId, type);
      return { shouldProcess: true, shouldResume: false, filePath };
    }

    // Check if we should resume processing
    const shouldResume =
      fileExists && hasStarted && !sourceState[type].completed;

    // Check if we should process at all
    const shouldProcess = !fileExists || shouldResume;

    if (fileExists && !shouldProcess) {
      console.log(
        `${type} file already exists and processing is complete for source ${sourceId}`,
      );
    }

    return { shouldProcess, shouldResume, filePath };
  }

  /**
   * Display overall progress of all processing steps
   * @param sources Array of data sources
   * @param final Whether this is the final progress display
   */
  public displayOverallProgress(
    sources: Array<{ id: string | number; name: string }>,
    final: boolean = false,
  ): void {
    console.log("\n=== OVERALL PROCESSING PROGRESS ===");

    // Track total completion
    let totalSteps = sources.length * 4; // 4 steps per source
    let completedSteps = 0;

    // Process each source
    for (const source of sources) {
      const sourceId = String(source.id);
      const sourceState = {
        ...StateManager.EMPTY_SOURCE_STATE,
        ...this.state.sources[sourceId],
      };

      if (!sourceState) {
        console.log(`Source ${sourceId}: Not started`);
        continue;
      }

      console.log(`\nSource ${sourceId} (${source.name}):`);

      // Sentences progress
      if (sourceState.sentences.completed) {
        console.log(
          `✅ Sentences: Complete (${sourceState.sentences.totalSentencesProcessed.toLocaleString()} sentences processed)`,
        );
        completedSteps++;
      } else if (sourceState.sentences.totalLines) {
        const progress = Math.round(
          (sourceState.sentences.processedLines /
            sourceState.sentences.totalLines) *
            100,
        );
        console.log(
          `🔄 Sentences: ${progress}% (${sourceState.sentences.processedLines.toLocaleString()}/${sourceState.sentences.totalLines.toLocaleString()} lines)`,
        );
      } else {
        console.log(`⏳ Sentences: Not started`);
      }

      // Words progress
      if (sourceState.words.completed) {
        console.log(
          `✅ Words: Complete (${sourceState.words.totalWordPairsProcessed.toLocaleString()} word pairs processed)`,
        );
        completedSteps++;
      } else if (sourceState.words.totalLines) {
        const progress = Math.round(
          (sourceState.words.processedLines / sourceState.words.totalLines) *
            100,
        );
        console.log(
          `🔄 Words: ${progress}% (${sourceState.words.processedLines.toLocaleString()}/${sourceState.words.totalLines.toLocaleString()} lines)`,
        );
      } else {
        console.log(`⏳ Words: Not started`);
      }

      // Distinct words progress
      if (sourceState.distinctWords.completed) {
        console.log(
          `✅ Distinct Words: Complete (${sourceState.distinctWords.uniqueWordsCount.toLocaleString()} unique words)`,
        );
        completedSteps++;
      } else if (sourceState.distinctWords.totalBytes) {
        const progress = Math.round(
          (sourceState.distinctWords.processedBytes /
            sourceState.distinctWords.totalBytes) *
            100,
        );
        const processedMB = (
          sourceState.distinctWords.processedBytes /
          (1024 * 1024)
        ).toFixed(2);
        const totalMB = (
          sourceState.distinctWords.totalBytes /
          (1024 * 1024)
        ).toFixed(2);
        console.log(
          `🔄 Distinct Words: ${progress}% (${processedMB}/${totalMB} MB)`,
        );
      } else {
        console.log(`⏳ Distinct Words: Not started`);
      }

      // Distinct word pairs progress
      if (sourceState.distinctWordPairs.completed) {
        console.log(
          `✅ Distinct Word Pairs: Complete (${sourceState.distinctWordPairs.uniquePairsCount.toLocaleString()} unique pairs)`,
        );
        completedSteps++;
      } else if (sourceState.distinctWordPairs.totalBytes) {
        const progress = Math.round(
          (sourceState.distinctWordPairs.processedBytes /
            sourceState.distinctWordPairs.totalBytes) *
            100,
        );
        const processedMB = (
          sourceState.distinctWordPairs.processedBytes /
          (1024 * 1024)
        ).toFixed(2);
        const totalMB = (
          sourceState.distinctWordPairs.totalBytes /
          (1024 * 1024)
        ).toFixed(2);
        console.log(
          `🔄 Distinct Word Pairs: ${progress}% (${processedMB}/${totalMB} MB)`,
        );
      } else {
        console.log(`⏳ Distinct Word Pairs: Not started`);
      }
    }

    // Display overall completion percentage
    const overallProgress = Math.round((completedSteps / totalSteps) * 100);
    console.log(
      `\nOverall Progress: ${overallProgress}% (${completedSteps}/${totalSteps} steps completed)`,
    );

    if (final) {
      console.log("\n🎉 All processing steps completed! 🎉\n");
    }

    console.log("=====================================\n");
  }
}

// Utility functions

/**
 * Format time in a human-readable format
 */
export function formatTime(seconds: number): string {
  if (!isFinite(seconds) || seconds <= 0) return "unknown";
  const hrs = Math.floor(seconds / 3600);
  const mins = Math.floor((seconds % 3600) / 60);
  const secs = Math.floor(seconds % 60);
  return `${hrs > 0 ? `${hrs}h ` : ""}${mins > 0 ? `${mins}m ` : ""}${secs}s`;
}

/**
 * Create a progress bar string
 */
export function createProgressBar(
  progress: number,
  length: number = 30,
): string {
  const filledLength = Math.round((length * progress) / 100);
  return "█".repeat(filledLength) + "░".repeat(length - filledLength);
}

/**
 * Display progress for a specific processing step
 */
export function displayProgress(
  type: ProcessingStepType,
  total: number,
  processed: number,
  additionalInfo: { [key: string]: any } = {},
  force: boolean = false,
): void {
  // Create a closure to track progress display state
  const getProgressDisplay = (() => {
    // Closure variables to track last update time and progress
    let lastUpdateTime = 0;
    let lastProcessed = 0;
    let startTime = Date.now();

    return (
      total: number,
      processed: number,
      additionalInfo: { [key: string]: any } = {},
      force: boolean = false,
    ) => {
      const now = Date.now();
      const UPDATE_THRESHOLD_MS = 1000; // Update display every 1 second
      const UPDATE_THRESHOLD_PROGRESS = total * 0.01; // Or every 1% progress

      // Only update if forced or thresholds are met
      if (
        !force &&
        now - lastUpdateTime < UPDATE_THRESHOLD_MS &&
        processed - lastProcessed < UPDATE_THRESHOLD_PROGRESS
      ) {
        return null;
      }

      // Update tracking variables
      lastUpdateTime = now;
      lastProcessed = processed;

      // Calculate progress percentage
      const progress =
        total > 0 ? Math.min(100, Math.round((processed / total) * 100)) : 0;

      // Create a progress bar
      const progressBar = createProgressBar(progress);

      // Calculate elapsed time and processing rate
      const elapsedSeconds = (now - startTime) / 1000;
      const rate = processed / Math.max(1, elapsedSeconds);

      // Calculate estimated time remaining
      const remaining = Math.max(0, total - processed);
      const estimatedTimeRemaining = remaining / Math.max(0.1, rate);

      // Build the display object
      const display = {
        title: `${
          type.charAt(0).toUpperCase() + type.slice(1)
        } Processing Progress`,
        progressBar: `[${progressBar}] ${progress}%`,
        processed: processed.toLocaleString(),
        total: total > 0 ? total.toLocaleString() : "unknown",
        rate: `${rate.toFixed(2)} items/sec`,
        elapsedTime: formatTime(elapsedSeconds),
        estimatedTimeRemaining: formatTime(estimatedTimeRemaining),
        lastUpdate: new Date().toLocaleTimeString(),
        ...additionalInfo,
      };

      return display;
    };
  })();

  // Get the progress display
  const display = getProgressDisplay(total, processed, additionalInfo, force);

  // If no update needed, return
  if (!display) return;

  // Clear console and display progress
  console.clear();
  console.log(display.title);
  console.log(display.progressBar);

  // Display processed/total
  if (type === "sentences" || type === "words") {
    console.log(`Lines: ${display.processed} / ${display.total}`);
  } else {
    console.log(`Bytes: ${display.processed} / ${display.total}`);
  }

  // Display additional info
  for (const [key, value] of Object.entries(additionalInfo)) {
    console.log(`${key}: ${value}`);
  }

  // Display timing info
  console.log(`Processing rate: ${display.rate}`);
  console.log(`Elapsed time: ${display.elapsedTime}`);
  console.log(`Estimated time remaining: ${display.estimatedTimeRemaining}`);
  console.log(`Last update: ${display.lastUpdate}`);
}
