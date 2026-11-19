/// plan_approve — plan 出环门（T9.1，2026-11-19）。plan 模式下模型把
/// 计划摘要呈给用户：批准 → 切出 plan 模式（default）并落盘，本回合
/// 即可开始执行；继续完善 / 放弃 → 决议回传给模型作为指引。REPL 里
/// 经 execute_ctx 挂真实交互（turn/ask.zig 的 planApproveExecute）；
/// 本桩只服务 headless（无用户可问，如实报告）。
const std = @import("std");
const registry = @import("registry.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, _: std.Io) anyerror!registry.ToolResult {
    const summary = registry.getStringField(input, "summary") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: summary") catch "", .is_error = true };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "no interactive user available (headless) — plan was NOT approved; summary: ");
    try out.appendSlice(alloc, summary);
    return registry.ToolResult{ .output = try out.toOwnedSlice(alloc) };
}
