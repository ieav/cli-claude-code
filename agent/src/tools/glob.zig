/// Glob tool — find files matching a pattern in a directory tree.
const std = @import("std");
const registry = @import("registry.zig");
const glob_match = @import("../util/glob_match.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const pattern = registry.getStringField(input, "pattern") orelse
        return registry.ToolResult{ .output = "Missing required field: pattern", .is_error = true };
    const path = registry.getStringField(input, "path") orelse ".";

    var results = std.ArrayList(u8).empty;
    defer results.deinit(alloc);

    // Use std.fs.cwd() with proper Zig 0.16 API
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return registry.ToolResult{
            .output = try alloc.print("Cannot open directory: {}", .{err}),
            .is_error = true,
        };
    };
    defer dir.close(io);

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        if (glob_match.matchPath(pattern, entry.path)) {
            try results.appendSlice(alloc, path);
            try results.append(alloc, '/');
            try results.appendSlice(alloc, entry.path);
            try results.append(alloc, '\n');
        }
    }

    return registry.ToolResult{ .output = try results.toOwnedSlice(alloc) };
}
