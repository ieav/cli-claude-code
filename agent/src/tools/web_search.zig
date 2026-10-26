/// WebSearch tool — search the web via the knowledge-tier WebSearch client.
/// Backend selection: BRAVE_API_KEY set -> Brave API; otherwise the keyless
/// DuckDuckGo HTML endpoint (no configuration needed).
const std = @import("std");
const registry = @import("registry.zig");
const env = @import("../util/env.zig");
const knowledge_search = @import("../knowledge/search.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const query = registry.getStringField(input, "query") orelse
        return registry.ToolResult{ .output = "Missing required field: query", .is_error = true };
    const max_results: usize = @intCast(registry.getIntField(input, "maxResults") orelse 5);

    const brave_key = env.get("BRAVE_API_KEY");
    const backend: knowledge_search.SearchBackend = if (brave_key != null) .brave else .duckduckgo;

    var ws = knowledge_search.WebSearch.init(
        alloc,
        io,
        backend,
        if (brave_key) |k| try alloc.dupe(u8, k) else null,
    );
    defer ws.deinit();

    const results = ws.search(query, max_results) catch |err| {
        return registry.ToolResult{
            .output = try std.fmt.allocPrint(alloc, "Web search failed ({s}): {s}", .{ @tagName(backend), @errorName(err) }),
            .is_error = true,
        };
    };
    defer ws.freeResults(results);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;

    if (results.len == 0) {
        try w.print("No results for '{s}' ({s}).", .{ query, @tagName(backend) });
    } else {
        try w.print("Web results for '{s}' via {s}:\n", .{ query, @tagName(backend) });
        for (results, 0..) |r, i| {
            try w.print("[{d}] {s}\n    {s}\n    {s}\n", .{ i + 1, r.title, r.url, r.snippet });
        }
    }

    var list = aw.toArrayList();
    return registry.ToolResult{ .output = try list.toOwnedSlice(alloc) };
}

fn webSearchIsConcurrencySafe(_: std.json.Value) bool {
    return true;
}
