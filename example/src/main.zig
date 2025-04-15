//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const bangla = @import("bangla");
const std = @import("std");

const batch_size = 10_000; // Larger batch size for writes
const buffer_size = 64 * 1024; // 64KB buffer for better I/O performance

pub fn main() !void {
    // Use arena allocator for better performance
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("Starting processing...\n", .{});

    const file = try std.fs.cwd().openFile("src/base.jsonl", .{ .mode = .read_only });
    defer file.close();

    const file_size = try file.getEndPos();
    std.debug.print("File size: {d} bytes\n", .{file_size});

    const word_file = try std.fs.cwd().createFile("src/words.csv", .{});
    defer word_file.close();

    const word_pairs_file = try std.fs.cwd().createFile("src/word_pairs.csv", .{});
    defer word_pairs_file.close();

    var unique_words = std.StringHashMap(void).init(allocator);
    defer {
        var it = unique_words.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        unique_words.deinit();
    }

    // Create buffered reader and writer
    var buffered_reader = std.io.bufferedReader(file.reader());
    const reader = buffered_reader.reader();
    var buffered_writer = std.io.bufferedWriter(word_file.writer());
    const writer = buffered_writer.writer();
    var buffered_pairs_writer = std.io.bufferedWriter(word_pairs_file.writer());
    const pairs_writer = buffered_pairs_writer.writer();

    var line_buffer = std.ArrayList(u8).init(allocator);
    defer line_buffer.deinit();

    var lines_processed: usize = 0;
    var unique_word_count: usize = 0;
    var total_pairs_count: usize = 0;
    var last_progress_time = std.time.milliTimestamp();

    // Process file line by line
    while (true) {
        reader.streamUntilDelimiter(line_buffer.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        // Parse JSON and process the line
        var parsed = std.json.parseFromSlice(Document, allocator, line_buffer.items, .{
            .ignore_unknown_fields = true,
        }) catch {
            line_buffer.clearRetainingCapacity();
            continue;
        };
        defer parsed.deinit();

        const value = parsed.value;
        if (value.revision.text != null) {
            var tokenizer = bangla.Tokenization.Tokenizer.init(value.revision.text.?, allocator);
            defer tokenizer.deinit();
            const words = tokenizer.getWords(.{}) catch {
                line_buffer.clearRetainingCapacity();
                continue;
            };
            defer allocator.free(words);

            // Process words and word pairs
            if (words.len > 0) {
                // Process individual words
                for (words) |word| {
                    const owned_word = allocator.dupe(u8, word) catch continue;
                    errdefer allocator.free(owned_word);

                    // Normalize the word
                    const normalized_word = normalizeWord(allocator, owned_word) catch |err| {
                        std.debug.print("Error normalizing word '{s}': {s}\n", .{ owned_word, @errorName(err) });
                        // owned_word is freed by errdefer
                        continue;
                    };
                    // Determine if normalization allocated new memory
                    const normalized_allocated_new = normalized_word.ptr != owned_word.ptr;
                    errdefer if (normalized_allocated_new) allocator.free(normalized_word);

                    // Check if the normalized word is unique
                    const result = unique_words.getOrPut(normalized_word) catch |err| {
                        std.debug.print("Error putting word '{s}' into map: {s}\n", .{ normalized_word, @errorName(err) });
                        // normalized_word is freed by errdefer (if new)
                        // owned_word is freed by outer errdefer
                        continue;
                    };

                    if (!result.found_existing) {
                        // If it's a new unique word, write it to the file
                        writer.print("{s}\n", .{normalized_word}) catch |err| {
                            // If writing fails, remove from map and free the map's copy
                            _ = unique_words.remove(normalized_word);
                            allocator.free(normalized_word); // Map owned it, free it
                            std.debug.print("Error writing word '{s}': {s}\n", .{ normalized_word, @errorName(err) });
                            // owned_word is freed by outer errdefer
                            continue;
                        };
                        unique_word_count += 1;
                        // The map now owns normalized_word.
                        // We only need to free the original copy.
                        allocator.free(owned_word);
                    } else {
                        // If the normalized word already exists, free the one we have (if new)
                        if (normalized_allocated_new) {
                            allocator.free(normalized_word);
                        }
                        // Free the original duplicate
                        allocator.free(owned_word);
                    }
                }

                // Process word pairs - write all pairs without uniqueness check
                for (words[0 .. words.len - 1], 0..) |word, i| {
                    const next_word = words[i + 1];

                    const normalized1 = normalizeWord(allocator, word) catch continue;
                    defer allocator.free(normalized1); // Free after use in this iteration

                    const normalized2 = normalizeWord(allocator, next_word) catch continue;
                    defer allocator.free(normalized2); // Free after use in this iteration

                    pairs_writer.print("{s},{s}\n", .{ normalized1, normalized2 }) catch |err| {
                        std.debug.print("Error writing word pair: {s}\n", .{@errorName(err)});
                        // defer handles freeing normalized1 and normalized2
                        continue;
                    };
                    total_pairs_count += 1;
                }
            }
        }

        lines_processed += 1;
        line_buffer.clearRetainingCapacity();

        // Show progress every second
        const current_time = std.time.milliTimestamp();
        if (current_time - last_progress_time >= 1000) {
            const progress_percent = @as(f64, @floatFromInt(file.getPos() catch 0)) / @as(f64, @floatFromInt(file_size)) * 100.0;
            std.debug.print("\rProgress: {d:.1}% | Lines: {d} | Unique Words: {d} | Total Pairs: {d}", .{
                progress_percent,
                lines_processed,
                unique_word_count,
                total_pairs_count,
            });
            last_progress_time = current_time;
            try buffered_writer.flush(); // Flush words periodically
            try buffered_pairs_writer.flush(); // Flush pairs periodically
        }
    }

    // Final flush of any remaining data
    try buffered_writer.flush();
    try buffered_pairs_writer.flush();

    std.debug.print("\nProcessing complete!\n", .{});
    std.debug.print("Total lines processed: {d}\n", .{lines_processed});
    std.debug.print("Total unique words: {d}\n", .{unique_word_count});
    std.debug.print("Total word pairs: {d}\n", .{total_pairs_count});
}

const Document = struct {
    title: ?[]const u8,
    revision: struct { text: ?[]const u8 },
};

const normalizeWord = @import("bangla").Tokenization.normalizeWord;
