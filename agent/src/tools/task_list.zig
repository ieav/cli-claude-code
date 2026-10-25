/// TaskList tool — list all tasks.
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, _: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    // TODO: Integrate with actual task system
    return registry.ToolResult{
        .output = try alloc.dupe(u8, "No tasks found. Task system integration pending."),
    };
}
