/**
 * Remove unwanted word sequences and characters from Bengali sentences
 * - Removes text inside brackets: (), [], {}, <>
 * - Removes non-Bengali characters except essential punctuation and spaces
 * - Normalizes whitespace and removes extra spaces
 * - Handles special cases like URLs, email addresses, and numbers
 */
function cleanupSentence(text: string): string {
  return (
    text
      // Remove text inside () along with the braces
      .replace(/\([^)]*\)/g, "")
      // Remove text inside [] along with the braces
      .replace(/\[.*?\]/g, "")
      // Remove text inside {} along with the braces
      .replace(/\{.*?\}/g, "")
      // Remove text inside <> along with the braces
      .replace(/<.*?>/g, "")
      // Remove URLs
      .replace(/https?:\/\/\S+/g, "")
      // Remove email addresses
      .replace(/\S+@\S+\.\S+/g, "")
      // Remove HTML entities (like &nbsp;, &#39;, etc.)
      .replace(/&[a-zA-Z0-9#]+;/g, "")
      // Remove Latin characters (a-z, A-Z)
      .replace(/[a-zA-Z]/g, "")
      // Keep only Bengali characters (Unicode range: \u0980-\u09FF),
      // spaces, and essential punctuation
      .replace(/[^\u0980-\u09FF\s।,.?!:-]/g, "")
      // Replace multiple consecutive spaces with a single space
      .replace(/\s+/g, " ")
      // Remove spaces before punctuation
      .replace(/\s([।,.?!:])/g, "$1")
      // Remove consecutive periods
      .replace(/\.+/g, ".")
      // Remove consecutive newlines
      .replace(/\n+/g, "\n")
      // Remove consecutive spaces
      .replace(/\s+/g, " ")
      // Remove consecutive -
      .replace(/\-+/g, "-")
      // Remove trailing - and _
      .replace(/[-_]$/g, "")
      // Remove complex patterns of punctuation and symbols at the beginning of sentences
      .replace(/^[-.:,।?!_\s]+/g, "")
      // Remove complex patterns of punctuation and symbols at the end of sentences
      .replace(/[-.:,।?!_\s]+$/g, "")
      // Trim whitespace from beginning and end
      .trim()
  );
}

/**
 * Split text into sentences by Bengalic KAR delimeter, new line, or multiple punctuation patterns
 */
export function cleanupSentences(text: string) {
  // Split by line break
  const paraSentences = text.split("\n");

  // Split by KAR delimeter and other standard sentence delimiters
  const karSentences = paraSentences.flatMap((sentence) =>
    sentence.split(/[।!?]/).filter(Boolean)
  );

  // Further split sentences by multiple punctuation patterns
  // This handles cases like ".,", "-,,.,,.," and other unusual punctuation clusters
  const furtherSplitSentences = karSentences.flatMap((sentence) => {
    // Pattern to match multiple punctuation marks together (2 or more)
    // This includes combinations of periods, commas, hyphens, etc.
    return sentence.split(/[.,:;-]{2,}/).filter(Boolean);
  });

  // Cleanup each sentence
  return new Set(
    furtherSplitSentences
      .map(cleanupSentence)
      .filter((sentence) => /[\u0980-\u09FF]/.test(sentence))
      .filter((sentence) => sentence.split(" ").length > 3)
      .filter(Boolean)
  );
}

export const displayProgress = (() => {
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
    force: boolean = false
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
        totalSize * (processedPages / validPosition)
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
      ).toFixed(2)}MB`
    );
    console.log(
      `Pages: ${processedPages} / ${
        maxPages === Infinity ? estimatedTotalPages + " (est.)" : maxPages
      } ${maxPages !== Infinity ? `(${pagesProgress}%)` : ""}`
    );
    console.log(`Current page: ${currentPage}`);
    console.log(`Processing rate: ${pagesPerSecond.toFixed(2)} pages/sec`);
    console.log(`Elapsed time: ${formatTime(elapsedSeconds)}`);
    console.log(
      `Estimated time remaining: ${formatTime(estimatedTimeRemaining)}`
    );
    console.log(`Last update: ${new Date().toLocaleTimeString()}`);
  };
})();
