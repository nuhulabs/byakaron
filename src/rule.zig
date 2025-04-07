const std = @import("std");
const mem = std.mem;
const json = std.json;

pub fn loadGrammar(allocator: std.mem.Allocator) !Grammar {
    const rules_json = @embedFile("rules.json");
    var typed_parsed = try std.json.parseFromSlice(GrammarFile, allocator, rules_json, .{});
    defer typed_parsed.deinit();

    const json_rules = typed_parsed.value;
    return Grammar.fromJson(json_rules, allocator);
}

// Grammar is the internal representation of the grammar
pub const Grammar = struct {
    const Rule = struct {
        matches: []const RuleMatch,
        replace: []const u8,

        fn fromJson(allocator: std.mem.Allocator, pattern: GrammarFile.JsonPattern) !?[]Grammar.Rule {
            if (pattern.rules == null or pattern.rules.?.len == 0) return null;

            var rules_array = try allocator.alloc(Grammar.Rule, pattern.rules.?.len);
            errdefer allocator.free(rules_array);

            for (pattern.rules.?, 0..) |rule, j| {
                const matches = try allocator.alloc(RuleMatch, rule.matches.len);
                errdefer allocator.free(matches);

                for (rule.matches, 0..) |match, k| {
                    matches[k] = try RuleMatch.fromJson(match, allocator);
                }

                const rule_replace = try duplicateAndFree(allocator, rule.replace);
                rules_array[j] = Grammar.Rule{
                    .matches = matches,
                    .replace = rule_replace,
                };
            }
            return rules_array;
        }
    };

    fn fromJson(json_grammar: GrammarFile, allocator: std.mem.Allocator) !Grammar {
        var rules = try allocator.alloc(Pattern, json_grammar.patterns.len);

        for (json_grammar.patterns, 0..) |pattern, i| {
            const find = try duplicateAndFree(allocator, pattern.find);
            const replace = try duplicateAndFree(allocator, pattern.replace);
            const pattern_rules = try Rule.fromJson(allocator, pattern);

            rules[i] = Pattern{
                .find = find,
                .replace = replace,
                .rules = pattern_rules,
            };
        }

        return Grammar{
            .vowel = stringToSet(json_grammar.vowel),
            .consonant = stringToSet(json_grammar.consonant),
            .casesensitive = stringToSet(json_grammar.casesensitive),
            .patterns = rules,
        };
    }

    vowel: std.StaticBitSet(256),
    consonant: std.StaticBitSet(256),
    casesensitive: std.StaticBitSet(256),
    patterns: []const Pattern,
};

const RuleMatch = struct {
    pub const Type = enum {
        suffix,
        prefix,

        pub fn fromString(str: []const u8) !Type {
            if (mem.eql(u8, str, "suffix")) return .suffix;
            if (mem.eql(u8, str, "prefix")) return .prefix;
            return error.InvalidRuleMatchType;
        }
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

    fn fromJson(json_rule_match: GrammarFile.JsonRuleMatch, allocator: std.mem.Allocator) !RuleMatch {
        const rule_match_type = try Type.fromString(json_rule_match.type);
        const scope = if (json_rule_match.scope) |s| try Scope.fromString(s) else null;
        const negative = if (json_rule_match.scope) |s| Scope.isNegative(s) else false;
        const value = if (json_rule_match.value) |v| try duplicateAndFree(allocator, v) else null;

        return RuleMatch{
            .type = rule_match_type,
            .scope = scope,
            .negative = negative,
            .value = value,
        };
    }

    type: Type,
    scope: ?Scope = null,
    negative: bool = false,
    value: ?[]const u8 = null,
};

pub const Pattern = struct {
    find: []const u8,
    replace: []const u8,
    rules: ?[]const Grammar.Rule = null,
};

// Grammar file is the original grammar file format
const GrammarFile = struct {
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

// Helper functions

fn duplicateAndFree(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const duped = try allocator.dupe(u8, data);
    errdefer allocator.free(duped);
    return duped;
}

fn stringToSet(data: []const u8) std.StaticBitSet(256) {
    var set = std.StaticBitSet(256).initEmpty();
    for (data) |c| set.set(c);
    return set;
}
