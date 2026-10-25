/// WebSearch tool — search the web using configured search API.
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const query = registry.getStringField(input, "query") orelse
        return registry.ToolResult{ .output = "Missing required field: query", .is_error = true };
    const max_results: u32 = @intCast(registry.getIntField(input, "maxResults") orelse 5);

    // TODO: Integrate with actual search API (Brave/SearXNG/DuckDuckGo)
    return registry.ToolResult{
        .output = try std.fmt.allocPrint(alloc, "Web search for '{s}' (max {d} results) — API integration pending", .{ query, max_results }),
    };
}

fn webSearchIsConcurrencySafe(_: std.json.Value) bool {
    return true;
}
