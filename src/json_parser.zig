const std = @import("std");
const mem = std.mem;
const json = std.json;

pub const Pattern = struct {
    find: []const u8,
    replace: []const u8,
    rules: ?[]const Rule = null,
};

pub const RuleMatch = struct {
    type: []const u8,
    scope: ?[]const u8 = null,
    value: ?[]const u8 = null,
};

pub const Rule = struct {
    matches: []const RuleMatch,
    replace: []const u8,
};

pub const Rules = []const Pattern;

pub fn loadRules(allocator: std.mem.Allocator) !Rules {
    const rules_json = @embedFile("rules.json");

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rules_json, .{});
    defer parsed.deinit();

    const patterns_value = parsed.value.object.get("patterns") orelse return error.MissingPatterns;
    const patterns = patterns_value.array.items;
    var rules = try allocator.alloc(Pattern, patterns.len);
    errdefer allocator.free(rules);

    for (patterns, 0..) |pattern, i| {
        const find_value = pattern.object.get("find") orelse return error.MissingFindField;
        const replace_value = pattern.object.get("replace") orelse return error.MissingReplaceField;

        const find = try allocator.dupe(u8, find_value.string);
        errdefer allocator.free(find);
        const replace = try allocator.dupe(u8, replace_value.string);
        errdefer allocator.free(replace);

        const rules_opt = pattern.object.get("rules");
        var pattern_rules: ?[]Rule = null;

        if (rules_opt != null and rules_opt.?.array.items.len > 0) {
            var rules_array = try allocator.alloc(Rule, rules_opt.?.array.items.len);
            errdefer allocator.free(rules_array);

            for (rules_opt.?.array.items, 0..) |rule, j| {
                const matches_value = rule.object.get("matches") orelse return error.MissingMatchesField;
                const rule_replace_value = rule.object.get("replace") orelse return error.MissingRuleReplaceField;

                const matches = try allocator.alloc(RuleMatch, matches_value.array.items.len);
                errdefer allocator.free(matches);

                for (matches_value.array.items, 0..) |match, k| {
                    const match_type_value = match.object.get("type") orelse return error.MissingMatchTypeField;
                    const match_type = try allocator.dupe(u8, match_type_value.string);
                    errdefer allocator.free(match_type);

                    const scope = if (match.object.get("scope")) |scope_val|
                        try allocator.dupe(u8, scope_val.string)
                    else
                        null;
                    errdefer if (scope) |s| allocator.free(s);

                    const value = if (match.object.get("value")) |value_val|
                        if (value_val == .null)
                            null
                        else
                            try allocator.dupe(u8, value_val.string)
                    else
                        null;
                    errdefer if (value) |v| allocator.free(v);

                    matches[k] = RuleMatch{
                        .type = match_type,
                        .scope = scope,
                        .value = value,
                    };
                }

                const rule_replace = try allocator.dupe(u8, rule_replace_value.string);
                errdefer allocator.free(rule_replace);

                rules_array[j] = Rule{
                    .matches = matches,
                    .replace = rule_replace,
                };
            }
            pattern_rules = rules_array;
        }

        rules[i] = Pattern{
            .find = find,
            .replace = replace,
            .rules = pattern_rules,
        };
    }

    return rules;
}

pub fn getPatterns() []const Pattern {
    return loadRules(std.heap.GeneralPurposeAllocator(.{}){}) catch unreachable;
}
