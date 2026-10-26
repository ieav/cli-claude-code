/// TaskCreate tool — create a tracked task in the session task store.
const std = @import("std");
const registry = @import("registry.zig");
const task_store = @import("task_store.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const subject = registry.getStringField(input, "subject") orelse
        return registry.ToolResult{ .output = "Missing required field: subject", .is_error = true };
    const description = registry.getStringField(input, "description") orelse "";

    const id = try task_store.global().create(subject, description);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("Task #{d} created: {s}", .{ id, subject });
    if (description.len > 0) try w.print("\n  {s}", .{description});
    var list = aw.toArrayList();
    return registry.ToolResult{ .output = try list.toOwnedSlice(alloc) };
}
