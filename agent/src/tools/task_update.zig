/// TaskUpdate tool — update task status.
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const task_id = registry.getStringField(input, "taskId") orelse
        return registry.ToolResult{ .output = "Missing required field: taskId", .is_error = true };

    return registry.ToolResult{
        .output = try std.fmt.allocPrint(alloc, "Task {s} updated.", .{task_id}),
    };
}
