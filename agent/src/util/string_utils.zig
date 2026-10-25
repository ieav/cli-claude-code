/// String utilities — ANSI-aware slicing, trimming, case conversion.
const std = @import("std");

/// Check if a string starts with a given prefix.
pub fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.mem.eql(u8, haystack[0..needle.len], needle);
}

/// Check if a string ends with a given suffix.
pub fn endsWith(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.mem.eql(u8, haystack[haystack.len - needle.len ..], needle);
}

/// Check if a string contains a substring.
pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Count occurrences of a substring.
pub fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |pos| {
        count += 1;
        start = pos + needle.len;
        if (start > haystack.len) break;
    }
    return count;
}

/// Trim whitespace from both ends.
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Repeat a string n times. Caller owns returned slice.
pub fn repeat(allocator: std.mem.Allocator, s: []const u8, n: usize) ![]u8 {
    if (n == 0) return allocator.dupe(u8, "");
    var result = try std.ArrayList(u8).initCapacity(allocator, s.len * n);
    defer result.deinit(allocator);
    for (0..n) |_| {
        try result.appendSlice(allocator, s);
    }
    return result.toOwnedSlice(allocator);
}

/// Truncate string to max_len, appending "..." if truncated.
/// Caller owns the returned slice.
pub fn truncate(allocator: std.mem.Allocator, s: []const u8, max_len: usize) ![]u8 {
    if (s.len <= max_len) return allocator.dupe(u8, s);
    if (max_len < 3) return allocator.dupe(u8, s[0..max_len]);
    return std.fmt.allocPrint(allocator, "{s}...", .{s[0 .. max_len - 3]});
}

/// Indent each line of a string by `indent` spaces. Caller owns returned slice.
pub fn indent(allocator: std.mem.Allocator, s: []const u8, spaces: usize) ![]u8 {
    const prefix = try repeat(allocator, " ", spaces);
    defer allocator.free(prefix);
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var lines = std.mem.splitSequence(u8, s, "\n");
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.append(allocator, '\n');
        try result.appendSlice(allocator, prefix);
        try result.appendSlice(allocator, line);
        first = false;
    }
    return result.toOwnedSlice(allocator);
}

test "startsWith/endsWith" {
    try std.testing.expect(startsWith("hello world", "hello"));
    try std.testing.expect(!startsWith("hello world", "world"));
    try std.testing.expect(endsWith("hello world", "world"));
    try std.testing.expect(!endsWith("hello world", "hello"));
}

test "countOccurrences" {
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("abcabc", "abc"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("abc", "xyz"));
}

test "truncate" {
    const alloc = std.testing.allocator;
    const t = try truncate(alloc, "hello world", 8);
    defer alloc.free(t);
    try std.testing.expectEqualStrings("hello...", t);
}
