/// TaskUpdate tool — change a task's status (pending/in_progress/completed).
const std = @import("std");
const registry = @import("registry.zig");
const task_store = @import("task_store.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const task_id_str = registry.getStringField(input, "taskId") orelse
        return registry.ToolResult{ .output = "Missing required field: taskId", .is_error = true };
    const status = registry.getStringField(input, "status") orelse
        return registry.ToolResult{ .output = "Missing required field: status (pending|in_progress|completed)", .is_error = true };

    const task_id = std.fmt.parseInt(usize, task_id_str, 10) catch
        return registry.ToolResult{ .output = "Invalid taskId: must be a number", .is_error = true };

    const store = task_store.global();
    if (!store.update(task_id, status)) {
        const task = store.find(task_id);
        const reason = if (task == null) "unknown task id" else "invalid status";
        return registry.ToolResult{
            .output = try alloc.print("Task update failed: {s}", .{reason}),
            .is_error = true,
        };
    }

    const task = store.find(task_id).?;
    return registry.ToolResult{
        .output = try alloc.print("Task #{d} → {s} — {s}", .{ task.id, task.status.label(), task.subject }),
    };
}
