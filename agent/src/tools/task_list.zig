/// TaskList tool — render all tasks in the session task store.
const std = @import("std");
const registry = @import("registry.zig");
const task_store = @import("task_store.zig");

pub fn execute(alloc: std.mem.Allocator, _: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    return registry.ToolResult{ .output = try task_store.global().render(alloc) };
}
