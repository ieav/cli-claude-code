/// AskUserQuestion tool — ask the user a question during tool execution.
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const question = registry.getStringField(input, "question") orelse
        return registry.ToolResult{ .output = "Missing required field: question", .is_error = true };

    // In real agent loop, this would prompt the user.
    // For now, return the question as output.
    return registry.ToolResult{
        .output = try alloc.print("[Question to user]: {s}\n(Awaiting user response)", .{question}),
    };
}
