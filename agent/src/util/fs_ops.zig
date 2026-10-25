/// Filesystem operations — cross-platform file/dir operations.
const std = @import("std");

/// Check if a file exists at the given path.
pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Check if a directory exists at the given path.
pub fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Ensure a directory exists, creating it and parents if necessary.
pub fn ensureDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Read a file's contents. Returns owned slice.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_size);
}

/// Write data to a file, creating it if necessary.
pub fn writeFile(path: []const u8, data: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

/// Copy a file from src to dst.
pub fn copyFile(src: []const u8, dst: []const u8) !void {
    try std.fs.cwd().copyFileTo(src, std.fs.cwd(), dst, .{});
}

/// Delete a file. Returns true if file was deleted, false if it didn't exist.
pub fn deleteFile(path: []const u8) bool {
    std.fs.cwd().deleteFile(path) catch return false;
    return true;
}

/// Get file size in bytes. Returns 0 if file doesn't exist.
pub fn fileSize(path: []const u8) !u64 {
    const stat = try std.fs.cwd().statFile(path);
    return stat.size;
}

/// Rename/move a file.
pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    try std.fs.cwd().rename(old_path, new_path);
}

/// List files in a directory. Caller owns returned slice and each element.
pub fn listDir(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var result = std.ArrayList([]u8).empty;
    defer result.deinit(allocator);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file) {
            const name = try allocator.dupe(u8, entry.name);
            try result.append(allocator, name);
        }
    }
    return result.toOwnedSlice(allocator);
}

test "fileExists" {
    try std.testing.expect(!fileExists("/nonexistent/file.txt"));
}

test "ensureDir" {
    const tmp = "/tmp/ziv_fs_test";
    try ensureDir(tmp);
    try std.testing.expect(dirExists(tmp));
    std.fs.cwd().deleteTree(tmp) catch {};
}
