/// Temporary file management — create and track temp files.
const std = @import("std");
const uuid = @import("uuid.zig");

/// Create a temporary file with a unique name. Returns the path.
/// Caller owns the returned path slice.
pub fn create(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    const id = try uuid.shortId(allocator);
    defer allocator.free(id);
    const name = try std.fmt.allocPrint(allocator, "{s}_{s}{s}", .{ prefix, id, suffix });
    errdefer allocator.free(name);

    // Create the temp directory if needed
    const tmp_dir = std.fs.cwd().makeOpenPath("/tmp", .{}) catch
        std.fs.cwd().makeOpenPath("./tmp", .{}) catch
        return error.TempDirFailed;

    // Create the file
    const file = tmp_dir.createFile(name, .{}) catch return error.TempCreateFailed;
    file.close();

    return std.fmt.allocPrint(allocator, "/tmp/{s}", .{name});
}

/// Create a temporary directory with a unique name. Returns the path.
/// Caller owns the returned path slice.
pub fn createDir(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const id = try uuid.shortId(allocator);
    defer allocator.free(id);
    const name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, id });
    errdefer allocator.free(name);

    std.fs.cwd().makePath(std.fmt.comptimePrint("/tmp/", .{})) catch {};

    const path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{name});
    std.fs.cwd().makePath(path) catch return error.TempDirCreateFailed;
    return path;
}

/// Write data to a temporary file. Returns the path.
/// Caller owns the returned path slice.
pub fn writeAll(allocator: std.mem.Allocator, prefix: []const u8, data: []const u8) ![]u8 {
    const path = try create(allocator, prefix, ".tmp");
    errdefer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);

    return path;
}

test "tempfile create" {
    const alloc = std.testing.allocator;
    const path = try create(alloc, "ziv_test", ".txt");
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        alloc.free(path);
    }
    try std.testing.expect(path.len > 0);
}
