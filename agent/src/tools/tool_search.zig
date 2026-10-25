/// ToolSearch tool — search available tools by keyword.
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const query = registry.getStringField(input, "query") orelse
        return registry.ToolResult{ .output = "Missing required field: query", .is_error = true };
    const tools_list = registry.default_tools;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(alloc);

    try output.appendSlice(alloc, "Matching tools:\n");

    var found: usize = 0;
    for (tools_list) |tool| {
        const match = std.mem.indexOf(u8, tool.name, query) != null or
            std.mem.indexOf(u8, tool.description, query) != null or
            (tool.search_hint != null and std.mem.indexOf(u8, tool.search_hint.?, query) != null);

        if (match) {
            try output.appendSlice(alloc, "  ");
            try output.appendSlice(alloc, tool.name);
            try output.appendSlice(alloc, ": ");
            try output.appendSlice(alloc, tool.description);
            try output.append(alloc, '\n');
            found += 1;
        }
    }

    if (found == 0) {
        try output.appendSlice(alloc, "  No tools found matching query.\n");
    }

    return registry.ToolResult{ .output = try output.toOwnedSlice(alloc) };
}

fn toolSearchIsConcurrencySafe(_: std.json.Value) bool {
    return true;
}
