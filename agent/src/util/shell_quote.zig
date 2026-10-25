/// Shell argument quoting — safe escaping for shell command arguments.
/// Prevents command injection in Bash tool execution.
const std = @import("std");

/// Characters that are safe to pass unquoted in a shell argument.
const safe_chars =
    \\ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=+.,/:@%~
;

/// Quote a single argument for shell execution.
/// If the argument contains only safe characters, return as-is.
/// Otherwise, wrap in single quotes and escape any internal single quotes.
/// Caller owns the returned slice.
pub fn quoteForShell(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    if (arg.len == 0) return allocator.dupe(u8, "''");

    // Check if all chars are safe
    var all_safe = true;
    for (arg) |ch| {
        if (std.mem.indexOfScalar(u8, safe_chars, ch) == null) {
            all_safe = false;
            break;
        }
    }
    if (all_safe) return allocator.dupe(u8, arg);

    // Need quoting — use single quotes, escaping internal single quotes
    // Strategy: replace ' with '\'' (end quote, escaped quote, start quote)
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    try result.append(allocator, '\'');

    for (arg) |ch| {
        if (ch == '\'') {
            try result.appendSlice(allocator, "'\\''");
        } else {
            try result.append(allocator, ch);
        }
    }
    try result.append(allocator, '\'');
    return result.toOwnedSlice(allocator);
}

/// Parse a shell command string into argv components.
/// Handles single quotes, double quotes, and backslash escaping.
/// Caller owns the returned slice and each element.
pub fn parseShellCommand(allocator: std.mem.Allocator, cmd: []const u8) ![][]u8 {
    var args = std.ArrayList([]u8).empty;
    defer args.deinit(allocator);

    var i: usize = 0;
    while (i < cmd.len) {
        // Skip whitespace
        while (i < cmd.len and cmd[i] == ' ') : (i += 1) {}
        if (i >= cmd.len) break;

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        while (i < cmd.len and cmd[i] != ' ') {
            if (cmd[i] == '\'') {
                // Single-quoted string — no escaping inside
                i += 1;
                while (i < cmd.len and cmd[i] != '\'') : (i += 1) {
                    try buf.append(allocator, cmd[i]);
                }
                if (i < cmd.len) i += 1; // skip closing quote
            } else if (cmd[i] == '"') {
                // Double-quoted string — handle backslash escaping
                i += 1;
                while (i < cmd.len and cmd[i] != '"') {
                    if (cmd[i] == '\\' and i + 1 < cmd.len) {
                        i += 1;
                        try buf.append(allocator, cmd[i]);
                    } else {
                        try buf.append(allocator, cmd[i]);
                    }
                    i += 1;
                }
                if (i < cmd.len) i += 1; // skip closing quote
            } else if (cmd[i] == '\\' and i + 1 < cmd.len) {
                // Backslash escape
                i += 1;
                try buf.append(allocator, cmd[i]);
                i += 1;
            } else {
                try buf.append(allocator, cmd[i]);
                i += 1;
            }
        }
        try args.append(allocator, try buf.toOwnedSlice(allocator));
    }
    return args.toOwnedSlice(allocator);
}

/// Build a safe shell command string from argv.
/// Each argument is properly quoted.
/// Caller owns the returned slice.
pub fn buildCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    for (argv, 0..) |arg, i| {
        if (i > 0) try result.append(allocator, ' ');
        const quoted = try quoteForShell(allocator, arg);
        defer allocator.free(quoted);
        try result.appendSlice(allocator, quoted);
    }
    return result.toOwnedSlice(allocator);
}

test "quoteForShell safe" {
    const alloc = std.testing.allocator;
    const q = try quoteForShell(alloc, "hello-world_123");
    defer alloc.free(q);
    try std.testing.expectEqualStrings("hello-world_123", q);
}

test "quoteForShell empty" {
    const alloc = std.testing.allocator;
    const q = try quoteForShell(alloc, "");
    defer alloc.free(q);
    try std.testing.expectEqualStrings("''", q);
}

test "quoteForShell spaces" {
    const alloc = std.testing.allocator;
    const q = try quoteForShell(alloc, "hello world");
    defer alloc.free(q);
    try std.testing.expectEqualStrings("'hello world'", q);
}

test "quoteForShell single quote" {
    const alloc = std.testing.allocator;
    const q = try quoteForShell(alloc, "it's");
    defer alloc.free(q);
    try std.testing.expectEqualStrings("'it'\\''s'", q);
}

test "parseShellCommand" {
    const alloc = std.testing.allocator;
    const args = try parseShellCommand(alloc, "echo 'hello world' foo");
    defer {
        for (args) |a| alloc.free(a);
        alloc.free(args);
    }
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("echo", args[0]);
    try std.testing.expectEqualStrings("hello world", args[1]);
    try std.testing.expectEqualStrings("foo", args[2]);
}
