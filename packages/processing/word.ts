import { Pool } from 'pg';
import { pipeline } from 'stream/promises';
import { Readable } from 'stream';
import cliProgress from 'cli-progress';
import { prisma, type DataTypes } from '@bnkt/db';


// Interface for a word entry
interface WordEntry {
  text: string;
  sentenceId: number;
  position: number;
  id?: number; // Will be populated after insertion
}

// Interface for a word group entry
interface WordGroupEntry {
  prevId: number;
  nextId: number;
  weight: number;
  occurance: number;
}

/**
 * Process sentences and extract words and word groups
 */
export async function processSentencesToWords(batchSize = 1000) {
  try {
    // Get total count of sentences for progress reporting
    const totalSentences = await prisma.sentences.count();
    
    console.log(`Found ${totalSentences} sentences to process`);
    
    // Create progress bar
    const progressBar = new cliProgress.SingleBar({
      format: 'Processing sentences |{bar}| {percentage}% | {value}/{total} sentences | ETA: {eta}s',
      barCompleteChar: '\u2588',
      barIncompleteChar: '\u2591',
      hideCursor: true
    });
    
    progressBar.start(totalSentences, 0);
    
    // Process in batches
    let processedCount = 0;
    let currentBatchSize = batchSize;
    
    while (processedCount < totalSentences) {
      // Adjust the last batch size if needed
      if (processedCount + currentBatchSize > totalSentences) {
        currentBatchSize = totalSentences - processedCount;
      }
      
      // Get a batch of sentences using Prisma
      const sentences = await prisma.sentences.findMany({
        select: {
          id: true,
          text: true
        },
        orderBy: {
          id: 'asc'
        },
        take: currentBatchSize,
        skip: processedCount
      });
      
      // Process this batch with transaction
      await processSentenceBatch(sentences);
      
      // Update progress
      processedCount += currentBatchSize;
      progressBar.update(processedCount);
    }
    
    progressBar.stop();
    console.log('Sentence processing completed successfully');
    
    return { success: true };
  } catch (error) {
    console.error('Error processing sentences:', error);
    return { success: false, error };
  } finally {
    await prisma.$disconnect();
  }
}

/**
 * Process a batch of sentences
 */
async function processSentenceBatch(sentences: any[]) {
  // Extract words from sentences
  const allWords: WordEntry[] = [];
  const wordTextToEntry = new Map<string, WordEntry>();
  
  // First pass: extract all words
  for (const sentence of sentences) {
    if (!sentence.text) continue;
    
    // Clean and tokenize the sentence
    const words = tokenizeSentence(sentence.text);
    
    // Create word entries
    words.forEach((word, position) => {
      const wordEntry: WordEntry = {
        text: word,
        sentenceId: sentence.id,
        position: position + 1
      };
      
      allWords.push(wordEntry);
      
      // Keep track of unique words by text
      if (!wordTextToEntry.has(word)) {
        wordTextToEntry.set(word, wordEntry);
      }
    });
  }

  // Use Prisma transaction for database operations
  await prisma.$transaction(async (tx) => {
    // Insert unique words and get their IDs
    const uniqueWords = Array.from(wordTextToEntry.values());
    await insertUniqueWords(uniqueWords, tx);
    
    // Get word IDs for all words
    const wordIdMap = new Map<string, number>();
    for (const [text, entry] of wordTextToEntry.entries()) {
      if (entry.id) {
        wordIdMap.set(text, entry.id);
      }
    }
    
    // Create word groups
    const wordGroups: WordGroupEntry[] = [];
    const wordGroupKey = new Set<string>();
    
    for (const sentence of sentences) {
      if (!sentence.text) continue;
      
      const words = tokenizeSentence(sentence.text);
      
      // Create word pairs
      for (let i = 0; i < words.length - 1; i++) {
        const prevWord = words[i];
        const nextWord = words[i + 1];
        
        const prevId = wordIdMap.get(prevWord);
        const nextId = wordIdMap.get(nextWord);
        
        if (prevId && nextId) {
          const key = `${prevId}-${nextId}`;
          
          // Check if we've already seen this pair in the current batch
          if (wordGroupKey.has(key)) {
            // Find and update the existing entry
            const existingGroup = wordGroups.find(g => g.prevId === prevId && g.nextId === nextId);
            if (existingGroup) {
              existingGroup.occurance += 1;
              existingGroup.weight += 1;
            }
          } else {
            // Add new word group
            wordGroups.push({
              prevId,
              nextId,
              weight: 1,
              occurance: 1
            });
            wordGroupKey.add(key);
          }
        }
      }
    }
    
    // Insert or update word groups
    await upsertWordGroups(wordGroups, tx);
  }, {
    maxWait: 15000, // 15 seconds max wait time
    timeout: 30000  // 30 seconds timeout
  });
}

/**
 * Tokenize a sentence into words
 */
function tokenizeSentence(text: string): string[] {
  // Clean the text and split into words
  // For Bangla text, we want to keep Bangla characters (Unicode range: \u0980-\u09FF)
  const cleanedText = text.replace(/[^\u0980-\u09FF\s]/g, '');
  return cleanedText.split(/\s+/).filter(word => word.length > 0);
}

/**
 * Insert unique words into the words table
 */
async function insertUniqueWords(words: WordEntry[], tx: DataTypes.PrismaClient) {
  if (words.length === 0) return;
  
  // Process words in smaller chunks to avoid query size limits
  const chunkSize = 100;
  for (let i = 0; i < words.length; i += chunkSize) {
    const chunk = words.slice(i, i + chunkSize);
    
    // For each word in the chunk, try to find or create it
    for (const word of chunk) {
      const existingWord = await tx.words.findUnique({
        where: { text: word.text },
        select: { id: true, text: true }
      });
      
      if (existingWord) {
        // Word exists, update the entry with its ID
        word.id = existingWord.id;
      } else {
        // Word doesn't exist, create it
        const newWord = await tx.words.create({
          data: {
            text: word.text,
            sentence_id: word.sentenceId,
            position: word.position
          },
          select: { id: true }
        });
        
        word.id = newWord.id;
      }
    }
  }
}

/**
 * Upsert word groups into the word_groups table
 */
async function upsertWordGroups(wordGroups: WordGroupEntry[], tx:  DataTypes.PrismaClient ) {
  if (wordGroups.length === 0) return;
  
  // Process word groups in smaller chunks to avoid query size limits
  const chunkSize = 100;
  for (let i = 0; i < wordGroups.length; i += chunkSize) {
    const chunk = wordGroups.slice(i, i + chunkSize);
    
    // For each word group in the chunk, upsert it
    for (const group of chunk) {
      await tx.word_groups.upsert({
        where: {
            prev_id_next_id: {
                prev_id: group.prevId,
                next_id: group.nextId
            }
        },
        update: {
          occurance: { increment: group.occurance },
          weight: { increment: group.weight }
        },
        create: {
          prev_id: group.prevId,
          next_id: group.nextId,
          weight: group.weight,
          occurance: group.occurance
        }
      });
    }
  }
}

// Export functions
export default {
  processSentencesToWords
};
