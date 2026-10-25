pub const content_type = "application/json";

pub const Request = struct {
    words: []const []const u8 = &.{},
};

pub const Suggestion = struct {
    word: []const u8 = "",
    frequency: i64 = 0,
    distance: usize = 0,
    score: i64 = 0,
};

pub const TokenResult = struct {
    token: []const u8 = "",
    known: bool = true,
    suggestions: []const Suggestion = &.{},
};

pub const Response = struct {
    results: []const TokenResult = &.{},
};
