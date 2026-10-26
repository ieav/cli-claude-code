/// Temporary file management — create and track temp files.
const std = @import("std");
const uuid = @import("uuid.zig");

/// Create a temporary file with a unique name. Returns the path.
/// Caller owns the returned path slice.
pub fn create(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    const id = try uuid.shortId(allocator);
    defer allocator.free(id);
    const path = try allocator.print("/tmp/{s}_{s}{s}", .{ prefix, id, suffix });
    errdefer allocator.free(path);

    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    // Ensure /tmp exists, then create the file by absolute path
    std.Io.Dir.cwd().createDirPath(io, "/tmp") catch {};
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return error.TempCreateFailed;
    file.close(io);

    return path;
}

/// Create a temporary directory with a unique name. Returns the path.
/// Caller owns the returned path slice.
pub fn createDir(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const id = try uuid.shortId(allocator);
    defer allocator.free(id);
    const name = try allocator.print("{s}_{s}", .{ prefix, id });
    errdefer allocator.free(name);

    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const path = try allocator.print("/tmp/{s}", .{name});
    std.Io.Dir.cwd().createDirPath(io, path) catch return error.TempDirCreateFailed;
    return path;
}

/// Write data to a temporary file. Returns the path.
pub fn writeAll(allocator: std.mem.Allocator, prefix: []const u8, data: []const u8) ![]u8 {
    const path = try create(allocator, prefix, ".tmp");
    errdefer allocator.free(path);

    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, io, &buf);
    try fw.interface.writeAll(data);
    try fw.interface.flush();

    return path;
}

test "tempfile create" {
    const alloc = std.testing.allocator;
    const path = try create(alloc, "ziv_test", ".txt");
    defer {
        var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        defer io_state.deinit();
        std.Io.Dir.cwd().deleteFile(io_state.io(), path) catch {};
        alloc.free(path);
    }
    try std.testing.expect(path.len > 0);
}
