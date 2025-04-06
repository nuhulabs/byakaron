const std = @import("std");
const mem = std.mem;
const json = std.json;

const JsonRuleFile = struct {
    vowel: []const u8,
    consonant: []const u8,
    casesensitive: []const u8,
    patterns: []const JsonPattern,

    pub const JsonPattern = struct {
        find: []const u8,
        replace: []const u8,
        rules: ?[]const JsonRule = null,
    };

    pub const JsonRule = struct {
        matches: []const JsonRuleMatch,
        replace: []const u8,
    };

    pub const JsonRuleMatch = struct {
        type: []const u8,
        scope: ?[]const u8 = null,
        value: ?[]const u8 = null,
    };
};

pub const Scope = enum {
    vowel,
    consonant,
    exact,
    punctuation,
    pub fn fromString(str: []const u8) !Scope {
        const is_negative = isNegative(str);
        const scope = str[if (is_negative) 1 else 0..];
        if (mem.eql(u8, scope, "vowel")) return .vowel;
        if (mem.eql(u8, scope, "consonant")) return .consonant;
        if (mem.eql(u8, scope, "exact")) return .exact;
        if (mem.eql(u8, scope, "punctuation")) return .punctuation;

        return error.InvalidScope;
    }

    pub fn isNegative(str: []const u8) bool {
        return str[0] == '!';
    }
};
pub const Pattern = struct {
    find: []const u8,
    replace: []const u8,
    rules: ?[]const Rule = null,
};

pub const RuleMatch = struct {
    type: []const u8,
    scope: ?Scope = null,
    negative: bool = false,
    value: ?[]const u8 = null,
};

pub const Rule = struct {
    matches: []const RuleMatch,
    replace: []const u8,
};

pub const Rules = []const Pattern;
pub const RootRule = struct {
    vowel: std.StaticBitSet(256),
    consonant: std.StaticBitSet(256),
    casesensitive: std.StaticBitSet(256),
    patterns: []const Pattern,
};

fn duplicateAndFree(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const duped = try allocator.dupe(u8, data);
    errdefer allocator.free(duped);
    return duped;
}

fn processPatternRules(allocator: std.mem.Allocator, pattern: JsonRuleFile.JsonPattern) !?[]Rule {
    if (pattern.rules == null or pattern.rules.?.len == 0) return null;

    var rules_array = try allocator.alloc(Rule, pattern.rules.?.len);
    errdefer allocator.free(rules_array);

    for (pattern.rules.?, 0..) |rule, j| {
        const matches = try allocator.alloc(RuleMatch, rule.matches.len);
        errdefer allocator.free(matches);

        for (rule.matches, 0..) |match, k| {
            const match_type = try duplicateAndFree(allocator, match.type);
            const scope = if (match.scope) |s| try Scope.fromString(s) else null;
            const value = if (match.value) |v| try duplicateAndFree(allocator, v) else null;
            errdefer if (value) |v| allocator.free(v);

            matches[k] = RuleMatch{
                .type = match_type,
                .scope = scope,
                .negative = if (match.scope) |s| Scope.isNegative(s) else false,
                .value = value,
            };
        }

        const rule_replace = try duplicateAndFree(allocator, rule.replace);
        rules_array[j] = Rule{
            .matches = matches,
            .replace = rule_replace,
        };
    }
    return rules_array;
}

pub fn loadRules(allocator: std.mem.Allocator) !RootRule {
    const rules_json = @embedFile("rules.json");
    var typed_parsed = try std.json.parseFromSlice(JsonRuleFile, allocator, rules_json, .{});
    defer typed_parsed.deinit();

    const json_rules = typed_parsed.value;

    const vowel = try duplicateAndFree(allocator, json_rules.vowel);
    const consonant = try duplicateAndFree(allocator, json_rules.consonant);
    const casesensitive = try duplicateAndFree(allocator, json_rules.casesensitive);

    var rules = try allocator.alloc(Pattern, json_rules.patterns.len);

    for (json_rules.patterns, 0..) |pattern, i| {
        const find = try duplicateAndFree(allocator, pattern.find);
        const replace = try duplicateAndFree(allocator, pattern.replace);
        const pattern_rules = try processPatternRules(allocator, pattern);

        rules[i] = Pattern{
            .find = find,
            .replace = replace,
            .rules = pattern_rules,
        };
    }

    const vowels = blk: {
        var set = std.StaticBitSet(256).initEmpty();
        for (vowel) |c| set.set(c);
        break :blk set;
    };

    const consonants = blk: {
        var set = std.StaticBitSet(256).initEmpty();
        for (consonant) |c| set.set(c);
        break :blk set;
    };

    const case_sensitive_chars = blk: {
        var set = std.StaticBitSet(256).initEmpty();
        for (casesensitive) |c| set.set(c);
        break :blk set;
    };

    return RootRule{
        .vowel = vowels,
        .consonant = consonants,
        .casesensitive = case_sensitive_chars,
        .patterns = rules,
    };
}

pub fn getPatterns() []const Pattern {
    return loadRules(std.heap.GeneralPurposeAllocator(.{}){}) catch unreachable;
}
