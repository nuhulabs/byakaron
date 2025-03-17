/**
 * unique_pairs.c - Count unique word pairs from a CSV file
 * 
 * This program reads a CSV file containing word pairs (value,next_value),
 * counts the occurrences of each unique pair, and writes the results to
 * a new CSV file with counts.
 * 
 * Compilation: gcc -o unique_pairs packages/dataset/c/unique_pairs.c -O3
 * Usage: ./unique_pairs <input_file> <output_file>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>

#define MAX_LINE_LENGTH 1024
#define MAX_WORD_LENGTH 256
#define INITIAL_HASHTABLE_SIZE 1000000  // Start with a large hash table to reduce resizing
#define LOAD_FACTOR_THRESHOLD 0.7

// Structure to represent a word pair
typedef struct {
    char first[MAX_WORD_LENGTH];
    char second[MAX_WORD_LENGTH];
    uint32_t count;
    bool occupied;
} WordPair;

// Hash table structure
typedef struct {
    WordPair* entries;
    size_t capacity;
    size_t size;
} HashTable;

// Initialize a hash table
HashTable* create_hash_table(size_t capacity) {
    HashTable* table = (HashTable*)malloc(sizeof(HashTable));
    if (!table) {
        perror("Failed to allocate memory for hash table");
        exit(EXIT_FAILURE);
    }
    
    table->capacity = capacity;
    table->size = 0;
    table->entries = (WordPair*)calloc(capacity, sizeof(WordPair));
    if (!table->entries) {
        perror("Failed to allocate memory for hash table entries");
        free(table);
        exit(EXIT_FAILURE);
    }
    
    return table;
}

// Hash function for word pairs (djb2 algorithm)
size_t hash_word_pair(const char* first, const char* second, size_t table_size) {
    uint64_t hash = 5381;
    int c;
    
    // Hash first word
    const char* str = first;
    while ((c = *str++)) {
        hash = ((hash << 5) + hash) + c; // hash * 33 + c
    }
    
    // Hash second word
    str = second;
    while ((c = *str++)) {
        hash = ((hash << 5) + hash) + c; // hash * 33 + c
    }
    
    return hash % table_size;
}

// Resize the hash table when it gets too full
void resize_hash_table(HashTable* table) {
    size_t old_capacity = table->capacity;
    WordPair* old_entries = table->entries;
    
    // Double the capacity
    size_t new_capacity = old_capacity * 2;
    WordPair* new_entries = (WordPair*)calloc(new_capacity, sizeof(WordPair));
    if (!new_entries) {
        perror("Failed to allocate memory for resized hash table");
        exit(EXIT_FAILURE);
    }
    
    // Create a new table with the new capacity
    HashTable new_table = {
        .entries = new_entries,
        .capacity = new_capacity,
        .size = 0
    };
    
    // Rehash all existing entries
    for (size_t i = 0; i < old_capacity; i++) {
        if (old_entries[i].occupied) {
            // Insert into the new table
            size_t index = hash_word_pair(old_entries[i].first, old_entries[i].second, new_capacity);
            
            // Linear probing to find an empty slot
            while (new_entries[index].occupied) {
                index = (index + 1) % new_capacity;
            }
            
            // Copy the entry
            new_entries[index] = old_entries[i];
            new_table.size++;
        }
    }
    
    // Free the old entries
    free(old_entries);
    
    // Update the table
    table->entries = new_entries;
    table->capacity = new_capacity;
    table->size = new_table.size;
    
    printf("Resized hash table from %zu to %zu entries\n", old_capacity, new_capacity);
}

// Insert or update a word pair in the hash table
void insert_or_update(HashTable* table, const char* first, const char* second) {
    // Check if we need to resize
    if ((double)table->size / table->capacity >= LOAD_FACTOR_THRESHOLD) {
        resize_hash_table(table);
    }
    
    // Calculate the hash
    size_t index = hash_word_pair(first, second, table->capacity);
    
    // Linear probing to find the entry or an empty slot
    while (table->entries[index].occupied) {
        // If we found the same pair, increment the count and return
        if (strcmp(table->entries[index].first, first) == 0 && 
            strcmp(table->entries[index].second, second) == 0) {
            table->entries[index].count++;
            return;
        }
        
        // Move to the next slot
        index = (index + 1) % table->capacity;
    }
    
    // If we get here, we found an empty slot for a new entry
    strncpy(table->entries[index].first, first, MAX_WORD_LENGTH - 1);
    table->entries[index].first[MAX_WORD_LENGTH - 1] = '\0';
    
    strncpy(table->entries[index].second, second, MAX_WORD_LENGTH - 1);
    table->entries[index].second[MAX_WORD_LENGTH - 1] = '\0';
    
    table->entries[index].count = 1;
    table->entries[index].occupied = true;
    table->size++;
}

// Get file size for progress reporting
long get_file_size(FILE* file) {
    long current_pos = ftell(file);
    fseek(file, 0L, SEEK_END);
    long size = ftell(file);
    fseek(file, current_pos, SEEK_SET);
    return size;
}

// Process the CSV file and count word pairs
HashTable* process_csv(const char* input_file) {
    FILE* file = fopen(input_file, "r");
    if (!file) {
        perror("Failed to open input file");
        exit(EXIT_FAILURE);
    }
    
    // Get file size for progress tracking
    long file_size = get_file_size(file);
    printf("Processing file: %s\n", input_file);
    printf("File size: %.2f MB\n", (double)file_size / (1024 * 1024));
    
    // Create hash table
    HashTable* table = create_hash_table(INITIAL_HASHTABLE_SIZE);
    
    char line[MAX_LINE_LENGTH];
    char first[MAX_WORD_LENGTH];
    char second[MAX_WORD_LENGTH];
    
    // Skip header line
    if (fgets(line, sizeof(line), file) == NULL) {
        fprintf(stderr, "Error reading header line or file is empty\n");
        fclose(file);
        return table;
    }
    
    // Track progress
    long bytes_processed = ftell(file);
    int last_reported_progress = 0;
    time_t start_time = time(NULL);
    
    // Process each line
    while (fgets(line, sizeof(line), file)) {
        // Update progress
        bytes_processed = ftell(file);
        int progress_percent = (int)((double)bytes_processed / file_size * 100);
        
        // Report progress every 5%
        if (progress_percent >= last_reported_progress + 5) {
            time_t current_time = time(NULL);
            double elapsed_seconds = difftime(current_time, start_time);
            double mb_processed = (double)bytes_processed / (1024 * 1024);
            double mb_per_second = elapsed_seconds > 0 ? mb_processed / elapsed_seconds : 0;
            
            printf("Processed %.2f MB (%d%%) - %.2f MB/s\n", 
                   mb_processed, progress_percent, mb_per_second);
            last_reported_progress = progress_percent;
        }
        
        // Remove newline character
        size_t len = strlen(line);
        if (len > 0 && line[len - 1] == '\n') {
            line[len - 1] = '\0';
        }
        
        // Skip empty lines
        if (strlen(line) == 0) {
            continue;
        }
        
        // Parse CSV line (simple parsing, assumes no commas in the words)
        if (sscanf(line, "%255[^,],%255[^,]", first, second) == 2) {
            // Insert or update the word pair in the hash table
            insert_or_update(table, first, second);
        }
    }
    
    fclose(file);
    printf("\nProcessing complete!\n");
    printf("Found %zu unique word pairs\n", table->size);
    
    return table;
}

// Write the results to a CSV file
void write_results(HashTable* table, const char* output_file) {
    FILE* file = fopen(output_file, "w");
    if (!file) {
        perror("Failed to open output file");
        exit(EXIT_FAILURE);
    }
    
    printf("Writing word pairs with counts to %s\n", output_file);
    
    // Write header
    fprintf(file, "value,next_value,count\n");
    
    // Track progress
    size_t total_pairs = table->size;
    size_t pairs_written = 0;
    int last_reported_progress = 0;
    
    // Write each word pair
    for (size_t i = 0; i < table->capacity; i++) {
        if (table->entries[i].occupied) {
            fprintf(file, "%s,%s,%u\n", 
                    table->entries[i].first, 
                    table->entries[i].second, 
                    table->entries[i].count);
            
            // Update progress
            pairs_written++;
            int progress_percent = (int)((double)pairs_written / total_pairs * 100);
            
            // Report progress every 5%
            if (progress_percent >= last_reported_progress + 5) {
                printf("Writing progress: %zu of %zu pairs (%d%%)\n", 
                       pairs_written, total_pairs, progress_percent);
                last_reported_progress = progress_percent;
            }
        }
    }
    
    fclose(file);
    printf("All data written and file closed successfully!\n");
}

// Free the hash table
void free_hash_table(HashTable* table) {
    free(table->entries);
    free(table);
}

int main(int argc, char* argv[]) {
    // Check command line arguments
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <input_file> <output_file>\n", argv[0]);
        return EXIT_FAILURE;
    }
    
    const char* input_file = argv[1];
    const char* output_file = argv[2];
    
    // Record start time
    time_t start_time = time(NULL);
    
    // Process the CSV file
    HashTable* table = process_csv(input_file);
    
    // Write the results
    write_results(table, output_file);
    
    // Free the hash table
    free_hash_table(table);
    
    // Calculate and print total execution time
    time_t end_time = time(NULL);
    double elapsed_seconds = difftime(end_time, start_time);
    printf("Total execution time: %.2f seconds\n", elapsed_seconds);
    
    return EXIT_SUCCESS;
}
