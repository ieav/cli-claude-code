//! BgTask tool — 模型对后台任务的自管理（对称性缺口补全：能启动就该
//! 能查看/停止）。/bg 面板是人用的；这是给模型的工具口。
//!   {"action":"status"}            全部任务一行一个
//!   {"action":"status","id":N}     单个任务
//!   {"action":"output","id":N}     输出预览（运行中=内存尾，已结束=落盘日志尾）
//!   {"action":"stop","id":N}       杀整组（bg_tasks.stop 同款语义）
//! 全部直通 bg_tasks 模块级机器（/bg 面板同款）——本文件只是工具皮。

const std = @import("std");
const registry = @import("registry.zig");
const bg_tasks = @import("bg_tasks.zig");
const util_time = @import("../util/time.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const action = registry.getStringField(input, "action") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Error: 'action' is required (status|output|stop)") catch "", .is_error = true };
    const id: ?u32 = if (registry.getIntField(input, "id")) |n|
        (if (n > 0) @intCast(n) else return registry.ToolResult{ .output = alloc.dupe(u8, "Error: id must be positive") catch "", .is_error = true })
    else
        null;

    if (std.mem.eql(u8, action, "status")) {
        return registry.ToolResult{ .output = try renderStatus(alloc, id) };
    }
    if (std.mem.eql(u8, action, "output")) {
        const sid = id orelse return registry.ToolResult{ .output = alloc.dupe(u8, "Error: output requires 'id'") catch "", .is_error = true };
        const out = bg_tasks.previewOf(alloc, io, sid) orelse
            return registry.ToolResult{ .output = try alloc.print("No such background task #{d}", .{sid}), .is_error = true };
        return registry.ToolResult{ .output = out };
    }
    if (std.mem.eql(u8, action, "stop")) {
        const sid = id orelse return registry.ToolResult{ .output = alloc.dupe(u8, "Error: stop requires 'id'") catch "", .is_error = true };
        if (bg_tasks.stop(sid)) {
            return registry.ToolResult{ .output = try alloc.print("Stopped background task #{d} (process group killed)", .{sid}) };
        }
        return registry.ToolResult{ .output = try alloc.print("Task #{d} is not running (already finished or unknown id)", .{sid}), .is_error = true };
    }
    return registry.ToolResult{ .output = alloc.dupe(u8, "Error: unknown action (use status|output|stop)") catch "", .is_error = true };
}

/// status 行渲染（/bg 面板同款信息密度，纯文本）。
fn renderStatus(alloc: std.mem.Allocator, id: ?u32) ![]u8 {
    const snaps = bg_tasks.snapshot(alloc) catch return alloc.dupe(u8, "snapshot failed") catch return error.OutOfMemory;
    defer {
        for (snaps) |s| alloc.free(s.command);
        alloc.free(snaps);
    }
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    var shown: usize = 0;
    for (snaps) |s| {
        if (id) |want| {
            if (s.id != want) continue;
        }
        shown += 1;
        if (s.running) {
            try w.print("[#{d}] running {d}s  {s}\n", .{ s.id, @divTrunc(s.elapsed_ms, 1000), s.command });
        } else if (s.signaled) {
            try w.print("[#{d}] killed  {s}\n", .{ s.id, s.command });
        } else {
            try w.print("[#{d}] exit {d}  {s}\n", .{ s.id, @as(u32, @intCast((s.exit_code >> 8) & 0xff)), s.command });
        }
    }
    if (shown == 0) {
        if (id != null) try w.print("No such background task #{d}\n", .{id.?});
        try w.writeAll("(no background tasks)\n");
    }
    return alloc.dupe(u8, aw.written());
}

/// 权限分级：stop 杀进程组=变更动作（default 模式走审批）；
/// status/output 纯读。与 Bash 工具的 bashIsReadOnly 同款思路。
pub fn bgTaskIsReadOnly(input: std.json.Value) bool {
    const action = registry.getStringField(input, "action") orelse return true;
    return !std.mem.eql(u8, action, "stop");
}

test "bgTaskIsReadOnly: only stop is a mutation" {
    try std.testing.expect(bgTaskIsReadOnly(.null));
    // parseFromSlice（非 Leaky）+ deinit——Leaky 版在 testing.allocator
    // 上就是泄漏（审查抓到，5 条 SafeAllocator 报告的来源）。
    const ps = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"action\":\"status\"}", .{});
    defer ps.deinit();
    try std.testing.expect(bgTaskIsReadOnly(ps.value));
    const pst = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"action\":\"stop\",\"id\":1}", .{});
    defer pst.deinit();
    try std.testing.expect(!bgTaskIsReadOnly(pst.value));
}
