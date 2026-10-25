/// TaskCreate tool — create a new task for tracking.
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const subject = registry.getStringField(input, "subject") orelse
        return registry.ToolResult{ .output = "Missing required field: subject", .is_error = true };
    const description = registry.getStringField(input, "description") orelse "";

    return registry.ToolResult{
        .output = try std.fmt.allocPrint(alloc, "Task created: {s}\n  {s}", .{ subject, description }),
    };
}
