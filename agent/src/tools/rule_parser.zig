/// Permission rule parser — parse and match permission rules.
/// Pattern: "ToolName(pattern)" or "ToolName"
const std = @import("std");
const registry = @import("registry.zig");

pub const ParsedRule = struct {
    tool_name: []const u8,
    pattern: ?[]const u8,
};

/// Parse a rule string like "Bash(git status)" into tool name and pattern.
pub fn parse(rule_str: []const u8) ?ParsedRule {
    const open_paren = std.mem.indexOfScalar(u8, rule_str, '(');
    if (open_paren) |op| {
        const close_paren = std.mem.indexOfScalarPos(u8, rule_str, op, ')') orelse return null;
        const tool = std.mem.trim(u8, rule_str[0..op], " ");
        const pattern = rule_str[op + 1 .. close_paren];
        if (tool.len == 0) return null;
        return .{
            .tool_name = tool,
            .pattern = if (pattern.len > 0) pattern else null,
        };
    }
    // No parentheses — entire string is tool name
    const tool = std.mem.trim(u8, rule_str, " ");
    if (tool.len == 0) return null;
    return .{
        .tool_name = tool,
        .pattern = null,
    };
}

/// Match a parsed rule against a tool name and input.
pub fn matches(rule: ParsedRule, tool_name: []const u8, input_json: []const u8) bool {
    if (!std.mem.eql(u8, rule.tool_name, tool_name)) return false;
    if (rule.pattern) |pattern| {
        if (std.mem.eql(u8, pattern, "*")) return true; // wildcard
        return std.mem.indexOf(u8, input_json, pattern) != null;
    }
    return true; // no pattern = match entire tool
}

/// Known dangerous command patterns that should be flagged.
pub const dangerous_patterns = [_][]const u8{
    "rm -rf /",
    "rm -rf ~",
    "dd if=/dev/zero",
    "mkfs.",
    ":(){:|:&};:",
    "> /dev/sd",
    "chmod -R 000 /",
    "curl *|*sh",
    "wget *|*sh",
};

/// Check if a command string matches any dangerous pattern.
pub fn isDangerousCommand(command: []const u8) bool {
    for (dangerous_patterns) |pattern| {
        if (std.mem.indexOf(u8, command, pattern) != null) return true;
    }
    return false;
}

test "parse rule" {
    const r1 = parse("Bash(git status)").?;
    try std.testing.expectEqualStrings("Bash", r1.tool_name);
    try std.testing.expectEqualStrings("git status", r1.pattern.?);

    const r2 = parse("FileRead").?;
    try std.testing.expectEqualStrings("FileRead", r2.tool_name);
    try std.testing.expect(r2.pattern == null);

    const r3 = parse("Bash(*)").?;
    try std.testing.expectEqualStrings("*", r3.pattern.?);
}

test "matches rule" {
    const r = parse("Bash(git status)").?;
    try std.testing.expect(matches(r, "Bash", "git status"));
    try std.testing.expect(!matches(r, "Bash", "git log"));
    try std.testing.expect(!matches(r, "FileRead", "git status"));
}
