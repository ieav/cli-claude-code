/// AskUserQuestion tool — headless stub body. In the REPL the execute_ctx
/// hook (turn/ask.zig) replaces this with the real interactive prompt;
/// this fallback only runs where there is no user to ask (headless test
/// harnesses), and says so instead of fabricating an answer.
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const question = registry.getStringField(input, "question") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: question") catch "", .is_error = true };

    // Surface the options too, so a headless caller at least sees what
    // was on the table.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "no interactive user available (headless) — question was: ");
    try out.appendSlice(alloc, question);
    if (input == .object) {
        if (input.object.get("options")) |oarr| {
            if (oarr == .array and oarr.array.items.len > 0) {
                try out.appendSlice(alloc, " | options: ");
                for (oarr.array.items, 0..) |it, i| {
                    if (it != .string) continue;
                    if (i > 0) try out.appendSlice(alloc, ", ");
                    try out.appendSlice(alloc, it.string);
                }
            }
        }
    }
    return registry.ToolResult{ .output = try out.toOwnedSlice(alloc) };
}
