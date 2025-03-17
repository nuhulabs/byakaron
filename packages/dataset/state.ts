import { existsSync, readFileSync, writeFileSync, mkdirSync } from "fs";
import * as path from "path";
import {
  STATE_FILE_PATH,
  SENTENCES_FILE,
  WORD_PAIRS_FILE,
  UNIQUE_WORDS_FILE,
  UNIQUE_WORD_PAIRS_FILE,
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
      wordsFilePath: path.join(sourceDirPath, WORD_PAIRS_FILE),
      distinctWordsFilePath: path.join(sourceDirPath, UNIQUE_WORDS_FILE),
      distinctWordPairsFilePath: path.join(
        sourceDirPath,
        UNIQUE_WORD_PAIRS_FILE,
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

      // Process each step type with a consistent display format
      completedSteps += this.displayStepProgress(sourceState, "sentences");
      completedSteps += this.displayStepProgress(sourceState, "words");
      completedSteps += this.displayStepProgress(sourceState, "distinctWords");
      completedSteps += this.displayStepProgress(sourceState, "distinctWordPairs");
    }

    // Display overall completion percentage and progress bar
    const overallProgress = Math.round((completedSteps / totalSteps) * 100);
    const progressBar = createProgressBar(overallProgress);
    
    console.log(`\nOverall Progress: ${progressBar} ${overallProgress}%`);
    console.log(`Steps completed: ${completedSteps}/${totalSteps}`);

    if (final) {
      console.log("\n🎉 All processing steps completed! 🎉\n");
    }

    console.log("=====================================\n");
  }

  /**
   * Display progress for a specific step
   * @param sourceState Source state
   * @param type Processing step type
   * @returns 1 if step is completed, 0 otherwise
   */
  private displayStepProgress(
    sourceState: SourceState,
    type: ProcessingStepType
  ): number {
    const stepState = sourceState[type];
    const stepName = formatStepName(type);
    
    if (stepState.completed) {
      // Get appropriate count for the step type
      let count = 0;
      let countLabel = "";
      
      if (type === "sentences") {
        count = (stepState as SentencesStep).totalSentencesProcessed;
        countLabel = "sentences";
      } else if (type === "words") {
        count = (stepState as WordsStep).totalWordPairsProcessed;
        countLabel = "word pairs";
      } else if (type === "distinctWords") {
        count = (stepState as DistinctWordsStep).uniqueWordsCount;
        countLabel = "unique words";
      } else if (type === "distinctWordPairs") {
        count = (stepState as DistinctWordPairsStep).uniquePairsCount;
        countLabel = "unique pairs";
      }
      
      console.log(`✅ ${stepName}: Complete (${count.toLocaleString()} ${countLabel})`);
      return 1; // Step completed
    } else {
      // Calculate progress based on step type
      let progress = 0;
      let progressDetail = "";
      
      if (type === "sentences" || type === "words") {
        const lineStep = stepState as LineBasedStep;
        if (lineStep.totalLines) {
          progress = Math.round((lineStep.processedLines / lineStep.totalLines) * 100);
          progressDetail = `${lineStep.processedLines.toLocaleString()}/${lineStep.totalLines.toLocaleString()} lines`;
        }
      } else {
        const byteStep = stepState as ByteBasedStep;
        if (byteStep.totalBytes) {
          progress = Math.round((byteStep.processedBytes / byteStep.totalBytes) * 100);
          const processedMB = (byteStep.processedBytes / (1024 * 1024)).toFixed(2);
          const totalMB = (byteStep.totalBytes / (1024 * 1024)).toFixed(2);
          progressDetail = `${processedMB}/${totalMB} MB`;
        }
      }
      
      if (progress > 0) {
        const progressBar = createProgressBar(progress, 20);
        console.log(`🔄 ${stepName}: ${progressBar} ${progress}% (${progressDetail})`);
      } else {
        console.log(`⏳ ${stepName}: Not started`);
      }
      
      return 0; // Step not completed
    }
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
 * @param progress Progress percentage (0-100)
 * @param length Length of the progress bar
 */
export function createProgressBar(
  progress: number,
  length: number = 30,
): string {
  const filledLength = Math.round((length * progress) / 100);
  return "█".repeat(filledLength) + "░".repeat(length - filledLength);
}

/**
 * Format step name for display
 * @param type Processing step type
 */
export function formatStepName(type: ProcessingStepType): string {
  switch (type) {
    case "sentences":
      return "Sentences";
    case "words":
      return "Words";
    case "distinctWords":
      return "Distinct Words";
    case "distinctWordPairs":
      return "Distinct Word Pairs";
    default:
      return type;
  }
}

/**
 * Display progress for a specific processing step
 * @param type Step type
 * @param total Total items to process
 * @param processed Number of processed items
 * @param additionalInfo Additional information to display
 * @param startTime Starting timestamp for calculating elapsed time
 */
export function logProgress(
  type: ProcessingStepType,
  total: number,
  processed: number,
  additionalInfo: Record<string, any> = {},
  startTime: number = Date.now(),
): void {
  // Calculate progress percentage
  const progress = total > 0 ? Math.min(100, Math.round((processed / total) * 100)) : 0;
  
  // Create a progress bar
  const progressBar = createProgressBar(progress);
  
  // Calculate elapsed time and processing rate
  const elapsedSeconds = (Date.now() - startTime) / 1000;
  const rate = processed / Math.max(1, elapsedSeconds);
  
  // Calculate estimated time remaining
  const remaining = Math.max(0, total - processed);
  const estimatedTimeRemaining = remaining / Math.max(0.1, rate);
  
  // Clear console and display progress
  console.clear();
  
  // Display header
  console.log(`=== ${formatStepName(type)} Processing ===`);
  
  // Display progress bar
  console.log(`Progress: ${progressBar} ${progress}%`);
  
  // Display processed/total
  if (type === "sentences" || type === "words") {
    console.log(`Lines: ${processed.toLocaleString()} / ${total.toLocaleString()}`);
  } else {
    const processedMB = (processed / (1024 * 1024)).toFixed(2);
    const totalMB = (total / (1024 * 1024)).toFixed(2);
    console.log(`Bytes: ${processedMB} MB / ${totalMB} MB`);
  }
  
  // Display additional info
  for (const [key, value] of Object.entries(additionalInfo)) {
    console.log(`${key}: ${value}`);
  }
  
  // Display timing info in a clean format
  console.log(`\nProcessing Metrics:`);
  console.log(`• Rate: ${rate.toFixed(2)} items/sec`);
  console.log(`• Elapsed: ${formatTime(elapsedSeconds)}`);
  console.log(`• Est. remaining: ${formatTime(estimatedTimeRemaining)}`);
  console.log(`• Last update: ${new Date().toLocaleTimeString()}`);
  
  console.log(`\n${"=".repeat(40)}`);
}
