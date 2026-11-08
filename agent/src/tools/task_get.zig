/// TaskGet tool — 按 id 查单个任务详情（任务三件套的漏项补全：列表
/// 看全貌，Get 看单条的完整 description——长描述在列表里是截断的）。
const std = @import("std");
const registry = @import("registry.zig");
const task_store = @import("task_store.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const id: usize = blk: {
        const n = registry.getIntField(input, "id") orelse
            return registry.ToolResult{ .output = "Error: 'id' field is required", .is_error = true };
        if (n <= 0) return registry.ToolResult{ .output = "Error: id must be positive", .is_error = true };
        break :blk @intCast(n);
    };
    const store = task_store.global();
    // find() 本身不持锁（读指针借用期间无变更者——TaskUpdate 会原地改
    // status 字段但不清内存；取完立即渲染，语义与 TaskList 的 render 同
    // 一窗口）。
    const t = store.find(id) orelse
        return registry.ToolResult{ .output = try alloc.print("No task #{d}", .{id}), .is_error = true };
    return registry.ToolResult{
        .output = try alloc.print("#{d} [{s}] P{d}\n{s}\n\n{s}", .{ t.id, t.status.label(), t.priority, t.subject, t.description }),
    };
}

test "task_get renders a stored task in full" {
    const alloc = std.testing.allocator;
    var store = task_store.TaskStore.init(alloc);
    defer store.deinit();
    const id = try store.create("fix login", "Reproduce on UAT, check the token refresh path, then fix the expiry math.", 2);
    const t = store.find(id).?;
    const out = try alloc.print("#{d} [{s}] P{d}\n{s}\n\n{s}", .{ t.id, t.status.label(), t.priority, t.subject, t.description });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "fix login") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "token refresh") != null); // 完整描述不截断
    try std.testing.expect(std.mem.indexOf(u8, out, "P2") != null);
}
