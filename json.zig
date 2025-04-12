const std = @import("std");

// Define your target struct
pub const Config = struct {
    name: []const u8,
    version: u32,
};

// Attempt to parse the embedded JSON at comptime
fn parseConfigComptime(comptime json_bytes: []const u8) !@Comptime() Config {
    const parser = std.json.Parser.init(json_bytes);
    var tokenizer = parser.tokenizer();

    // This part needs to be carefully crafted for comptime evaluation
    // It might require manual token consumption and struct creation.
    // std.json.parseFromSlice is NOT @Comptime() in Zig 0.14.

    var config: Config = undefined;

    // Example of manual parsing (very basic and error-prone for real JSON)
    try tokenizer.expect(.LBrace);

    try tokenizer.expectKey("name");
    try tokenizer.expect(.Colon);
    config.name = try tokenizer.parseStringAlloc(@Comptime()); // Might not be fully comptime alloc

    try tokenizer.expect(.Comma);
    try tokenizer.expectKey("version");
    try tokenizer.expect(.Colon);
    config.version = try tokenizer.parseUnsigned(u32);

    try tokenizer.expect(.RBrace);
    try tokenizer.expect(.End);

    return config;
}

// Embed your JSON file
const configFileContent = @embedFile("config.json");

// Attempt to parse the embedded content at comptime
comptime {
    const config = try parseConfigComptime(configFileContent);
    std.debug.print("Comptime Config: {{ name = '{s}', version = {} }}\n", .{ config.name, config.version });

    // You can now use 'config' in comptime contexts
    if (config.version >= 2) {
        std.debug.print("Newer version detected at comptime!\n", .{});
    }
}

pub fn main() !void {
    // You might not need to parse again at runtime if the comptime parsing was successful
    // const config = try std.json.parseFromSlice(Config, configFileContent, .{}) catch |err| {
    //     std.debug.print("Runtime parse error: {}\n", .{err});
    //     return err;
    // };
    // std.debug.print("Runtime Config: {{ name = '{s}', version = {} }}\n", .{ config.name, config.version });
}

// Create a dummy config.json file for testing
// echo '{"name": "MyApp", "version": 2}' > config.json