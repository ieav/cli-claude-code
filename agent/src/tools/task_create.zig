/// TaskCreate tool — create a tracked task in the session task store.
const std = @import("std");
const registry = @import("registry.zig");
const task_store = @import("task_store.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const subject = registry.getStringField(input, "subject") orelse
        return registry.ToolResult{ .output = "Missing required field: subject", .is_error = true };
    const description = registry.getStringField(input, "description") orelse "";
    // P3: optional priority 1-5 (5 highest, default 3) — orders the task
    // list and mirrors the subagent dispatch claim order.
    var priority: u8 = 3;
    if (registry.getIntField(input, "priority")) |p| {
        priority = @intCast(std.math.clamp(p, 1, 5));
    }

    const id = try task_store.global().create(subject, description, priority);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("Task #{d} created: {s}", .{ id, subject });
    if (priority != 3) try w.print("\n  优先级 {d}/5", .{priority});
    if (description.len > 0) try w.print("\n  {s}", .{description});
    var list = aw.toArrayList();
    return registry.ToolResult{ .output = try list.toOwnedSlice(alloc) };
}
