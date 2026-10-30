/// WebSearch tool — search the web via the knowledge-tier WebSearch client.
/// Backend selection: BRAVE_API_KEY set -> Brave API; otherwise the keyless
/// DuckDuckGo HTML endpoint (no configuration needed).
const std = @import("std");
const registry = @import("registry.zig");
const env = @import("../util/env.zig");
const knowledge_search = @import("../knowledge/search.zig");

/// T5.1 source chain: primary first, then the fallback. With a Brave key
/// the order is Brave → DuckDuckGo (keyless); without one there is only
/// DDG. Pure so the ordering is unit-testable.
pub fn sourceOrder(has_brave_key: bool) [2]?knowledge_search.SearchBackend {
    if (has_brave_key) return .{ .brave, .duckduckgo };
    return .{ .duckduckgo, null };
}

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const query = registry.getStringField(input, "query") orelse
        return registry.ToolResult{ .output = "Missing required field: query", .is_error = true };
    const max_results: usize = @intCast(registry.getIntField(input, "maxResults") orelse 5);

    const brave_key = env.get("BRAVE_API_KEY");
    const order = sourceOrder(brave_key != null);

    var results: []knowledge_search.SearchResult = &.{};
    var used: ?knowledge_search.SearchBackend = null;
    var last_err: ?anyerror = null;
    for (order) |maybe_backend| {
        const backend = maybe_backend orelse break;
        var ws = knowledge_search.WebSearch.init(
            alloc,
            io,
            backend,
            if (backend == .brave and brave_key != null) try alloc.dupe(u8, brave_key.?) else null,
        );
        defer ws.deinit();
        const r = ws.search(query, max_results) catch |err| {
            last_err = err;
            continue; // T5.1: fall through to the next source
        };
        if (r.len == 0) {
            ws.freeResults(r);
            last_err = error.NoResults; // empty primary → try the fallback
            continue;
        }
        results = r;
        used = backend;
        break;
    }
    const backend_used = used orelse {
        return registry.ToolResult{
            .output = try alloc.print("Web search failed (all sources): {s}", .{@errorName(last_err orelse error.NoResults)}),
            .is_error = true,
        };
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;

    // Source attribution survives the fallback (T5.1): the model sees
    // which engine answered.
    try w.print("Web results for '{s}' via {s}:\n", .{ query, @tagName(backend_used) });
    for (results, 0..) |r, i| {
        try w.print("[{d}] {s}\n    {s}\n    {s}\n", .{ i + 1, r.title, r.url, r.snippet });
    }
    defer {
        // freeResults only needs the allocator — inline it here instead of
        // fabricating a throwaway WebSearch instance.
        for (results) |*r| r.deinit(alloc);
        alloc.free(results);
    }

    var list = aw.toArrayList();
    return registry.ToolResult{ .output = try list.toOwnedSlice(alloc) };
}

test "sourceOrder chains brave to ddg only with a key (T5.1)" {
    const with_key = sourceOrder(true);
    try std.testing.expect(with_key[0] == .brave);
    try std.testing.expect(with_key[1] == .duckduckgo);
    const keyless = sourceOrder(false);
    try std.testing.expect(keyless[0] == .duckduckgo);
    try std.testing.expect(keyless[1] == null);
}

fn webSearchIsConcurrencySafe(_: std.json.Value) bool {
    return true;
}
