/// FileRead tool — reads file contents with line numbers.

const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const path = getStringField(input, "path") orelse
        return registry.ToolResult{ .output = "Error: 'path' field is required", .is_error = true };

    const max_size: usize = 1024 * 1024;

    const contents = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, std.Io.Limit.limited(max_size)) catch |err| {
        const msg = std.fmt.allocPrint(alloc, "Failed to read '{s}': {}", .{ path, err }) catch "read failed";
        return registry.ToolResult{ .output = msg, .is_error = true };
    };

    // Format with line numbers
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    var line_num: usize = 1;
    var iter = std.mem.splitSequence(u8, contents, "\n");
    while (iter.next()) |line| : (line_num += 1) {
        const formatted = std.fmt.allocPrint(alloc, "{d:6}\t{s}\n", .{ line_num, line }) catch continue;
        defer alloc.free(formatted);
        result.appendSlice(alloc, formatted) catch {};
    }

    alloc.free(contents);
    return registry.ToolResult{ .output = result.toOwnedSlice(alloc) catch "format failed" };
}

fn getStringField(input: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = input.object.get(key) orelse return null;
    if (obj != .string) return null;
    return obj.string;
}
