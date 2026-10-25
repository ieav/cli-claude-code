/// Glob pattern matching — simple wildcard matching for file paths.
/// Supports: * (any chars), ? (single char), ** (recursive directory match).
const std = @import("std");

/// Check if a filename matches a glob pattern.
/// Supports: * (match any sequence), ? (match single char).
pub fn match(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: ?usize = null;

    while (ti < text.len) {
        if (pi < pattern.len) {
            if (pattern[pi] == '?') {
                pi += 1;
                ti += 1;
                continue;
            }
            if (pattern[pi] == '*') {
                star_pi = pi;
                star_ti = ti;
                pi += 1;
                continue;
            }
            if (pattern[pi] == text[ti]) {
                pi += 1;
                ti += 1;
                continue;
            }
        }
        if (star_pi) |spi| {
            pi = spi + 1;
            ti = star_ti.? + 1;
            star_ti = ti;
            continue;
        }
        return false;
    }

    // Consume trailing * in pattern
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

/// Check if a path matches a glob pattern with ** support.
/// ** matches any number of directories.
pub fn matchPath(pattern: []const u8, path: []const u8) bool {
    // Handle ** for recursive directory matching
    if (std.mem.indexOf(u8, pattern, "**")) |doublestar| {
        // Split pattern at ** and match prefix + suffix
        const prefix = pattern[0..doublestar];
        const suffix = if (doublestar + 2 < pattern.len) pattern[doublestar + 3 ..] else "";

        if (prefix.len > 0) {
            if (!std.mem.startsWith(u8, path, prefix)) return false;
        }

        if (suffix.len == 0) return true;

        // Find suffix match anywhere in path
        var start: usize = if (prefix.len > 0) prefix.len -| 1 else 0;
        while (start <= path.len) : (start += 1) {
            // Advance to next path separator or end
            if (start > 0 and path[start - 1] != '/' and start < path.len) continue;
            if (matchPath(suffix, path[start..])) return true;
        }
        return false;
    }

    // For simple patterns, match against the filename
    const filename = std.fs.path.basename(path);
    if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
        // Pattern has no path separator — match filename only
        return match(pattern, filename);
    }

    return match(pattern, path);
}

test "glob match basic" {
    try std.testing.expect(match("*.zig", "main.zig"));
    try std.testing.expect(!match("*.zig", "main.ts"));
    try std.testing.expect(match("test_?.zig", "test_a.zig"));
    try std.testing.expect(!match("test_?.zig", "test_ab.zig"));
    try std.testing.expect(match("*", "anything"));
    try std.testing.expect(match("a*b", "axyzb"));
}

test "glob matchPath" {
    try std.testing.expect(matchPath("*.zig", "src/main.zig"));
    try std.testing.expect(matchPath("src/**/*.zig", "src/tools/registry.zig"));
    try std.testing.expect(!matchPath("*.zig", "src/main.ts"));
}
