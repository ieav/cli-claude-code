/// Path utilities — resolution, normalization, relative paths, extension extraction.
const std = @import("std");

/// Get the file extension (including dot) from a path, or null if none.
pub fn extension(path: []const u8) ?[]const u8 {
    const basename = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return null;
    if (dot == 0) return null; // hidden files like .gitignore
    return basename[dot..];
}

/// Get the filename without extension.
pub fn stem(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return basename;
    if (dot == 0) return basename;
    return basename[0..dot];
}

/// Normalize a path — resolve "." and ".." components, remove trailing slashes.
/// Caller owns the returned slice.
pub fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    var is_absolute = (path.len > 0 and path[0] == '/');

    var it = std.mem.splitSequence(u8, path, "/");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) {
                _ = parts.pop();
            } else {
                is_absolute = false;
            }
            continue;
        }
        try parts.append(allocator, part);
    }

    if (parts.items.len == 0) {
        if (is_absolute) return allocator.dupe(u8, "/");
        return allocator.dupe(u8, ".");
    }

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    if (is_absolute) try result.append(allocator, '/');
    for (parts.items, 0..) |part, i| {
        if (i > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }
    return result.toOwnedSlice(allocator);
}

/// Join path components with OS-specific separator.
/// Caller owns the returned slice.
pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

/// Check if a path is inside a given directory (prefix match on normalized paths).
pub fn isInsidePath(child_path: []const u8, parent_path: []const u8) bool {
    if (child_path.len < parent_path.len) return false;
    if (!std.mem.eql(u8, child_path[0..parent_path.len], parent_path)) return false;
    if (parent_path.len == child_path.len) return true;
    return child_path[parent_path.len] == '/';
}

/// Get the relative path from `base` to `target`. Returns target if not relative.
/// Caller owns the returned slice.
pub fn relative(allocator: std.mem.Allocator, base: []const u8, target: []const u8) ![]u8 {
    return std.fs.path.relative(allocator, base, target);
}

test "extension" {
    try std.testing.expectEqualStrings(".zig", extension("src/main.zig").?);
    try std.testing.expectEqualStrings(".tar.gz", extension("archive.tar.gz").?);
    try std.testing.expect(extension("README") == null);
}

test "stem" {
    try std.testing.expectEqualStrings("main", stem("src/main.zig"));
    try std.testing.expectEqualStrings("README", stem("README"));
}

test "normalize" {
    const alloc = std.testing.allocator;
    const n = try normalize(alloc, "/a/b/../c/./d");
    defer alloc.free(n);
    try std.testing.expectEqualStrings("/a/c/d", n);
}

test "isInsidePath" {
    try std.testing.expect(isInsidePath("/home/user/project/file.zig", "/home/user/project"));
    try std.testing.expect(!isInsidePath("/home/user/other/file.zig", "/home/user/project"));
}
