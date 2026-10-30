/// Agent dispatch tool (T6.3-T6.5) — parallel subagent fan-out. The MAIN
/// agent spawns 1-3 focused read-only subagents (agent/subagent.zig) and
/// gets their merged reports. Concurrency rides the REPL's ThreadPool
/// (T3.1) with a hard cap of 3; without a pool it degrades to serial.
const std = @import("std");
const registry = @import("registry.zig");
const runtime_registry = @import("runtime_registry.zig");
const llm = @import("../llm/mod.zig");
const subagent = @import("../agent/subagent.zig");
const task_pool = @import("../task/thread_pool.zig");
const tokens = @import("../util/tokens.zig");
const util_time = @import("../util/time.zig");
const openai = @import("../llm/openai.zig");
const claude = @import("../llm/claude.zig");
const ollama = @import("../llm/ollama.zig");

pub const MAX_SUBAGENTS: usize = 3;
const SUMMARY_TOKEN_CAP: u32 = 500;
const DISPATCH_TIMEOUT_MS: i64 = 120_000;

/// Context built once by the REPL: everything a worker needs to construct
/// its OWN provider instance (no sharing with the streaming main loop)
/// plus the shared read-only tool registry and the pool.
pub const DispatchCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    tools: *runtime_registry.RuntimeRegistry,
    pool: ?*task_pool.ThreadPool,
    backend: llm.BackendType,
    model: []const u8,
    api_key: ?[]const u8,
    base_url: ?[]const u8,
    ollama_host: []const u8,
};

/// One pool job: runs a subagent to completion and parks the result.
const AgentJob = struct {
    ctx: *DispatchCtx,
    task_text: []u8, // owned by ctx.alloc
    result: ?subagent.SubagentResult = null,
    failed: bool = false,
};

pub fn executeWithCtx(opaque_ctx: ?*anyopaque, alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    _ = io;
    const ctx: *DispatchCtx = @ptrCast(@alignCast(opaque_ctx orelse return error.NoContext));

    // tasks: array of strings, or single "task" string.
    var tasks: std.ArrayList([]const u8) = .empty;
    defer tasks.deinit(alloc);
    if (input == .object) {
        if (input.object.get("tasks")) |arr| {
            if (arr == .array) {
                for (arr.array.items) |it| {
                    if (it == .string) try tasks.append(alloc, it.string);
                }
            }
        } else if (input.object.get("task")) |t| {
            if (t == .string) try tasks.append(alloc, t.string);
        }
    }
    if (tasks.items.len == 0) {
        return registry.ToolResult{ .output = "Missing field: tasks (array of task descriptions)", .is_error = true };
    }
    const n = @min(tasks.items.len, MAX_SUBAGENTS);

    var jobs: [MAX_SUBAGENTS]AgentJob = undefined;
    var pool_tasks: [MAX_SUBAGENTS]task_pool.Task = undefined;
    var submitted: usize = 0;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        jobs[i] = .{ .ctx = ctx, .task_text = try ctx.alloc.dupe(u8, tasks.items[i]) };
    }

    // T6.4 DEVIATION (stability): subagents run SERIALLY on the main
    // thread, each with a private provider over the main io — the exact
    // thread model the reflection timeout worker has used in production.
    // Pool fan-out is parked: concurrent std.Io.Threaded instances hung
    // the process at teardown (3/3 repro), and 0.17 documents no
    // multi-instance threading contract. The pool stays wired (T3.1) for
    // re-enabling once that contract is clear.
    _ = &submitted;
    _ = &pool_tasks;
    i = 0;
    while (i < n) : (i += 1) {
        const provider = makeProvider(ctx, ctx.io) catch {
            jobs[i].failed = true;
            continue;
        };
        defer provider.deinit();
        jobs[i].result = subagent.run(.{
            .task = jobs[i].task_text,
            .alloc = ctx.alloc,
            .io = ctx.io,
            .provider = provider,
            .tools = ctx.tools,
        });
    }

    // T6.5: merge — each summary capped at ~500 tokens with per-agent stats.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    i = 0;
    while (i < n) : (i += 1) {
        defer if (jobs[i].result) |r| r.deinit(ctx.alloc);
        defer ctx.alloc.free(jobs[i].task_text);
        try w.print("## 子任务 {d}\n", .{i + 1});
        if (jobs[i].result) |r| {
            const cut = subagent.utf8TokenCut(r.summary, SUMMARY_TOKEN_CAP);
            try w.print("{s}\n(轮次 {d} · 工具调用 {d})\n", .{ cut, r.turns_used, r.tool_calls });
            if (cut.len < r.summary.len) try w.writeAll("(截断)\n");
        } else if (jobs[i].failed) {
            try w.writeAll("(子代理执行失败)\n");
        } else {
            try w.writeAll("(超时被取消)\n");
        }
    }
    var list = aw.toArrayList();
    return registry.ToolResult{ .output = try list.toOwnedSlice(alloc) };
}

fn makeProvider(ctx: *DispatchCtx, job_io: std.Io) !llm.Provider {
    switch (ctx.backend) {
        .openai => {
            var p = openai.OpenAIProvider.init(ctx.alloc, job_io, .{
                .api_key = ctx.api_key orelse return error.MissingApiKey,
                .model = ctx.model,
                .base_url = ctx.base_url orelse "https://api.openai.com/v1",
            });
            return p.toProvider();
        },
        .claude => {
            var p = claude.ClaudeProvider.init(ctx.alloc, job_io, .{
                .api_key = ctx.api_key orelse return error.MissingApiKey,
                .model = ctx.model,
                .base_url = ctx.base_url orelse "https://api.anthropic.com",
            });
            return p.toProvider();
        },
        .ollama => {
            var p = ollama.OllamaProvider.init(ctx.alloc, job_io, .{
                .model = ctx.model,
                .base_url = ctx.ollama_host,
            });
            return p.toProvider();
        },
    }
}



test "dispatch constants stay bounded" {
    try std.testing.expectEqual(@as(usize, 3), MAX_SUBAGENTS);
    try std.testing.expect(SUMMARY_TOKEN_CAP == 500);
}
