/// Input sanitization — clean and validate user/tool inputs.
const std = @import("std");

/// Sanitize a file path — reject path traversal attempts.
/// Returns error if path contains ".." traversal or null bytes.
pub fn sanitizeFilePath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyPath;
    for (path) |ch| {
        if (ch == 0) return error.NullByte;
    }
    // Check for ".." traversal
    var it = std.mem.splitSequence(u8, path, "/");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.PathTraversal;
    }
}

/// Check if a path is a protected system path that should never be modified.
pub fn isProtectedPath(path: []const u8) bool {
    const protected = [_][]const u8{
        "/etc/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/System/",
        "\\Windows\\",
        "\\Program Files\\",
    };
    for (protected) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

/// Check if a path is within a project's .git directory.
pub fn isGitPath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/.git/") != null or
        std.mem.indexOf(u8, path, "\\.git\\") != null or
        std.mem.endsWith(u8, path, "/.git") or
        std.mem.endsWith(u8, path, "\\.git");
}

/// Check if a path is within .claude directory.
pub fn isClaudePath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/.claude/") != null or
        std.mem.indexOf(u8, path, "\\.claude\\") != null;
}

/// Sanitize a shell command — detect obvious injection patterns.
/// This is NOT comprehensive security, just a first-pass filter.
pub fn detectInjectionPattern(command: []const u8) ?[]const u8 {
    // Check for common injection patterns
    const dangerous = [_]struct { pattern: []const u8, reason: []const u8 }{
        .{ .pattern = "rm -rf /", .reason = "recursive root delete" },
        .{ .pattern = ":(){:|:&};:", .reason = "fork bomb" },
        .{ .pattern = "dd if=/dev/zero", .reason = "disk overwrite" },
        .{ .pattern = "mkfs.", .reason = "filesystem format" },
        .{ .pattern = "> /dev/sd", .reason = "direct device write" },
    };
    for (dangerous) |d| {
        if (std.mem.indexOf(u8, command, d.pattern) != null) return d.reason;
    }
    return null;
}

test "sanitizeFilePath" {
    try sanitizeFilePath("/home/user/file.txt");
    try std.testing.expectError(error.PathTraversal, sanitizeFilePath("../../../etc/passwd"));
    try std.testing.expectError(error.EmptyPath, sanitizeFilePath(""));
}

test "isProtectedPath" {
    try std.testing.expect(isProtectedPath("/etc/passwd"));
    try std.testing.expect(!isProtectedPath("/home/user/project/file.zig"));
}

test "detectInjectionPattern" {
    try std.testing.expect(detectInjectionPattern("rm -rf /") != null);
    try std.testing.expect(detectInjectionPattern("echo hello") == null);
}
