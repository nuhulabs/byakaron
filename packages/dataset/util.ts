import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";

export const displayProgressLegacy = (() => {
  // Closure variables to track last update time and progress
  let lastUpdateTime = 0;
  let lastProcessedPages = 0;
  let startTime = Date.now();

  return function (
    totalSize: number,
    currentPosition: number,
    processedPages: number,
    maxPages: number,
    currentPage: string,
    force: boolean = false,
  ) {
    const now = Date.now();
    const UPDATE_THRESHOLD_MS = 1000; // Update display every 1 second
    const UPDATE_THRESHOLD_PAGES = 5; // Or every 5 pages

    // Only update if forced or thresholds are met
    if (
      !force &&
      now - lastUpdateTime < UPDATE_THRESHOLD_MS &&
      processedPages - lastProcessedPages < UPDATE_THRESHOLD_PAGES
    ) {
      return;
    }

    // Update tracking variables
    lastUpdateTime = now;
    lastProcessedPages = processedPages;

    // Ensure currentPosition is valid and not greater than totalSize
    const validPosition = Math.min(currentPosition || 0, totalSize);

    const progress =
      totalSize > 0
        ? Math.min(100, Math.round((validPosition / totalSize) * 100))
        : 0;
    const pagesProgress =
      maxPages !== Infinity
        ? Math.min(100, Math.round((processedPages / maxPages) * 100))
        : 0;

    // Create a progress bar
    const barLength = 30;
    const filledLength = Math.round((barLength * progress) / 100);
    const progressBar =
      "█".repeat(filledLength) + "░".repeat(barLength - filledLength);

    // Calculate elapsed time and processing rate
    const elapsedSeconds = (now - startTime) / 1000;
    const pagesPerSecond = processedPages / Math.max(1, elapsedSeconds);

    // Calculate estimated total pages more safely
    let estimatedTotalPages = maxPages;
    if (maxPages === Infinity && validPosition > 0 && totalSize > 0) {
      estimatedTotalPages = Math.round(
        totalSize * (processedPages / validPosition),
      );
    }

    const remainingPages = Math.max(0, estimatedTotalPages - processedPages);
    const estimatedTimeRemaining =
      remainingPages / Math.max(0.1, pagesPerSecond);

    // Format time remaining
    const formatTime = (seconds: number): string => {
      if (!isFinite(seconds) || seconds <= 0) return "unknown";
      const hrs = Math.floor(seconds / 3600);
      const mins = Math.floor((seconds % 3600) / 60);
      const secs = Math.floor(seconds % 60);
      return `${hrs > 0 ? `${hrs}h ` : ""}${
        mins > 0 ? `${mins}m ` : ""
      }${secs}s`;
    };

    console.clear();
    console.log("Wiki XML to JSONL Transformation Progress");
    console.log(`[${progressBar}] ${progress}%`);
    console.log(
      `File: ${(validPosition / (1024 * 1024)).toFixed(2)}MB / ${(
        totalSize /
        (1024 * 1024)
      ).toFixed(2)}MB`,
    );
    console.log(
      `Pages: ${processedPages} / ${
        maxPages === Infinity ? estimatedTotalPages + " (est.)" : maxPages
      } ${maxPages !== Infinity ? `(${pagesProgress}%)` : ""}`,
    );
    console.log(`Current page: ${currentPage}`);
    console.log(`Processing rate: ${pagesPerSecond.toFixed(2)} pages/sec`);
    console.log(`Elapsed time: ${formatTime(elapsedSeconds)}`);
    console.log(
      `Estimated time remaining: ${formatTime(estimatedTimeRemaining)}`,
    );
    console.log(`Last update: ${new Date().toLocaleTimeString()}`);
  };
})();

/**
 * Generic progress display function that can handle different types of progress tracking
 */
export const displayProgress = (() => {
  // Closure variables to track last update time and progress
  let lastUpdateTime = 0;
  let lastProcessedItems = 0;
  let startTime = Date.now();

  return function (options: {
    title: string;
    totalItems: number;
    processedItems: number;
    currentBatchSize?: number;
    additionalStats?: Array<{ label: string; value: string | number }>;
    force?: boolean;
  }) {
    const {
      title,
      totalItems,
      processedItems,
      currentBatchSize,
      additionalStats = [],
      force = false,
    } = options;

    const now = Date.now();
    const UPDATE_THRESHOLD_MS = 1000; // Update display every 1 second
    const UPDATE_THRESHOLD_ITEMS = 1000; // Or every 1000 items

    // Only update if forced or thresholds are met
    if (
      !force &&
      now - lastUpdateTime < UPDATE_THRESHOLD_MS &&
      processedItems - lastProcessedItems < UPDATE_THRESHOLD_ITEMS
    ) {
      return;
    }

    // Update tracking variables
    lastUpdateTime = now;
    lastProcessedItems = processedItems;

    // Calculate progress percentage
    const progress =
      totalItems > 0
        ? Math.min(100, Math.round((processedItems / totalItems) * 100))
        : 0;

    // Create a progress bar
    const barLength = 30;
    const filledLength = Math.round((barLength * progress) / 100);
    const progressBar =
      "█".repeat(filledLength) + "░".repeat(barLength - filledLength);

    // Calculate elapsed time and processing rate
    const elapsedSeconds = (now - startTime) / 1000;
    const itemsPerSecond = processedItems / Math.max(1, elapsedSeconds);

    // Calculate estimated time remaining
    const remainingItems = Math.max(0, totalItems - processedItems);
    const estimatedTimeRemaining =
      remainingItems / Math.max(0.1, itemsPerSecond);

    // Format time
    const formatTime = (seconds: number): string => {
      if (!isFinite(seconds) || seconds <= 0) return "unknown";
      const hrs = Math.floor(seconds / 3600);
      const mins = Math.floor((seconds % 3600) / 60);
      const secs = Math.floor(seconds % 60);
      return `${hrs > 0 ? `${hrs}h ` : ""}${
        mins > 0 ? `${mins}m ` : ""
      }${secs}s`;
    };

    // Clear console and display progress
    console.clear();
    console.log(`${title} Progress`);
    console.log(`[${progressBar}] ${progress}%`);
    console.log(
      `Processed: ${processedItems.toLocaleString()} / ${
        totalItems > 0 ? totalItems.toLocaleString() : "unknown"
      }`,
    );

    if (currentBatchSize !== undefined) {
      console.log(`Current batch size: ${currentBatchSize.toLocaleString()}`);
    }

    // Display additional stats if provided
    additionalStats.forEach(({ label, value }) => {
      console.log(`${label}: ${value.toLocaleString()}`);
    });

    console.log(`Processing rate: ${itemsPerSecond.toFixed(2)} items/sec`);
    console.log(`Elapsed time: ${formatTime(elapsedSeconds)}`);
    console.log(
      `Estimated time remaining: ${formatTime(estimatedTimeRemaining)}`,
    );
    console.log(`Last update: ${new Date().toLocaleTimeString()}`);
  };
})();

/**
 * Count the number of lines in a file
 */
export async function countFileLines(filePath: string): Promise<number> {
  return new Promise((resolve) => {
    let lineCount = 0;
    const rl = createInterface({
      input: createReadStream(filePath),
      crlfDelay: Infinity,
    });

    rl.on("line", () => lineCount++);
    rl.on("close", () => resolve(lineCount));
  });
}
