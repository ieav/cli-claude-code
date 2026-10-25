/// Grep tool — search file contents for patterns using ripgrep or built-in search.
const std = @import("std");
const registry = @import("registry.zig");
const ripgrep = @import("../util/ripgrep.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const pattern = registry.getStringField(input, "pattern") orelse
        return registry.ToolResult{ .output = "Missing required field: pattern", .is_error = true };
    const path = registry.getStringField(input, "path") orelse ".";
    const max_results: u32 = @intCast(registry.getIntField(input, "maxResults") orelse 100);

    const search_result = ripgrep.search(alloc, pattern, path, io) catch {
        return simpleSearch(alloc, pattern, path, max_results);
    };

    var output = std.ArrayList(u8).empty;
    defer output.deinit(alloc);

    var count: u32 = 0;
    for (search_result.matches) |m| {
        if (count >= max_results) break;
        const line = std.fmt.allocPrint(alloc, "{s}:{d}: {s}\n", .{ m.file_path, m.line_number, m.line_content }) catch continue;
        defer alloc.free(line);
        output.appendSlice(alloc, line) catch continue;
        count += 1;
    }

    if (count == 0) {
        try output.appendSlice(alloc, "No matches found.\n");
    }

    return registry.ToolResult{ .output = try output.toOwnedSlice(alloc) };
}

fn simpleSearch(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, max_results: u32) anyerror!registry.ToolResult {
    _ = path;
    _ = max_results;
    return registry.ToolResult{
        .output = try std.fmt.allocPrint(allocator, "Pattern: {s} (simple search not yet implemented)", .{pattern}),
    };
}

fn grepIsConcurrencySafe(_: std.json.Value) bool {
    return true;
}
