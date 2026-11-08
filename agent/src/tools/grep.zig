/// Grep tool — search file contents for patterns using ripgrep or built-in search.
const std = @import("std");
const registry = @import("registry.zig");
const ripgrep = @import("../util/ripgrep.zig");
const code_index = @import("../knowledge/code_index.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const pattern = registry.getStringField(input, "pattern") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: pattern") catch "", .is_error = true };
    const path = registry.getStringField(input, "path") orelse ".";
    const max_results: u32 = @intCast(registry.getIntField(input, "maxResults") orelse 100);

    // P6 dual-path: a PLAIN LITERAL pattern can be served by the code
    // index (FTS is keyword, not regex) — no rg spawn at all. Any stale hit
    // (file changed since it was indexed) forces the real scan below.
    if (code_index.isLiteralPattern(pattern)) {
        const r = code_index.queryLiteral(alloc, io, pattern, path, max_results);
        var served = r.stats.served_from_index;
        defer {
            for (r.matches) |*m| code_index.freeMatch(alloc, m.*);
            if (r.matches.len > 0) alloc.free(r.matches);
        }
        if (served) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(alloc);
            for (r.matches) |m| {
                const line = alloc.print("{s}:{d}: {s}\n", .{ m.path, m.lineno, m.body }) catch continue;
                defer alloc.free(line);
                out.appendSlice(alloc, line) catch continue;
            }
            out.appendSlice(alloc, "\x1b[2m[…索引命中 — .ziv/index.db]\x1b[0m\n") catch {};
            return registry.ToolResult{ .output = try out.toOwnedSlice(alloc) };
        }
        _ = &served;
    }

    const search_result = ripgrep.search(alloc, pattern, path, io) catch |err| switch (err) {
        error.NoSearchBackend => return registry.ToolResult{
            .output = alloc.dupe(u8, "Error: neither rg nor grep is available on PATH") catch "",
            .is_error = true,
        },
        error.SearchTimedOut => return registry.ToolResult{
            .output = try alloc.print("Error: search timed out after 30s: {s}", .{pattern}),
            .is_error = true,
        },
        else => return registry.ToolResult{
            .output = try alloc.print("Error: search failed: {}", .{err}),
            .is_error = true,
        },
    };

    defer ripgrep.freeResult(alloc, search_result);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(alloc);

    var count: u32 = 0;
    for (search_result.matches) |m| {
        if (count >= max_results) break;
        const line = alloc.print("{s}:{d}: {s}\n", .{ m.file_path, m.line_number, m.line_content }) catch continue;
        defer alloc.free(line);
        output.appendSlice(alloc, line) catch continue;
        count += 1;
    }

    if (count == 0) {
        try output.appendSlice(alloc, "No matches found.\n");
    } else if (search_result.truncated) {
        try output.appendSlice(alloc, "… (search output truncated — narrow the pattern or path)\n");
    }

    return registry.ToolResult{ .output = try output.toOwnedSlice(alloc) };
}

fn grepIsConcurrencySafe(_: std.json.Value) bool {
    return true;
}
