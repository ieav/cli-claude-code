/// Agent dispatch tool (T6.3-T6.5, P2 re-opened T6.4) — parallel subagent
/// fan-out. The MAIN agent spawns up to 3 focused read-only subagents
/// (agent/subagent.zig) and gets their merged reports. Concurrency is
/// configurable (settings.subagent_concurrency, default 3); each worker
/// thread owns a PRIVATE Io.Threaded + provider (B-pattern — sharing the
/// main loop's io across threads is unsafe at the std layer) and claims
/// jobs through a shared atomic index in priority-descending order. The
/// calling thread joins the worker pool; spawn failures degrade to fewer
/// workers, never to a hang (the P1 stall watchdog caps every request).
const std = @import("std");
const registry = @import("registry.zig");
const runtime_registry = @import("runtime_registry.zig");
const llm = @import("../llm/mod.zig");
const subagent = @import("../agent/subagent.zig");
const tokens = @import("../util/tokens.zig");
const event_bus = @import("../task/event_bus.zig");
const openai = @import("../llm/openai.zig");
const claude = @import("../llm/claude.zig");
const ollama = @import("../llm/ollama.zig");

pub const MAX_SUBAGENTS: usize = 3;
const SUMMARY_TOKEN_CAP: u32 = 500;

/// Context built once by the REPL: everything a worker needs to construct
/// its OWN provider instance (no sharing with the streaming main loop)
/// plus the shared read-only tool registry.
pub const DispatchCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    tools: *runtime_registry.RuntimeRegistry,
    backend: llm.BackendType,
    model: []const u8,
    api_key: ?[]const u8,
    base_url: ?[]const u8,
    ollama_host: []const u8,
    /// P2: workers per dispatch — a POINTER into the live settings so /config
    /// changes apply to the next dispatch without rebuilding the ctx.
    /// Clamped to 1..8 at the config layer; 1 runs everything on the
    /// calling thread (the serial escape hatch).
    concurrency: *const u32,
    /// P3: session event bus for task_completed/task_failed emits
    /// (main-thread emit only — the dispatch itself runs on the calling
    /// thread, which IS the main thread).
    bus: ?*event_bus.EventBus = null,
};

/// One job slot: the task text (owned by ctx.alloc) plus its result,
/// written by exactly ONE worker — no locking needed.
const AgentJob = struct {
    ctx: *DispatchCtx,
    task_text: []u8,
    result: ?subagent.SubagentResult = null,
    failed: bool = false,
    /// P3: live turn counter (observed by the subagent's progress hook)
    /// and the retry bookkeeping.
    progress: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    failed_turns: usize = 0,
    retried: bool = false,
};

pub fn executeWithCtx(opaque_ctx: ?*anyopaque, alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    _ = io;
    const ctx: *DispatchCtx = @ptrCast(@alignCast(opaque_ctx orelse return error.NoContext));

    // tasks: array of strings, or single "task" string. Optional aligned
    // "priorities" array (ints; default 0) orders worker claims.
    var tasks: std.ArrayList([]const u8) = .empty;
    defer tasks.deinit(alloc);
    var prios_buf: [MAX_SUBAGENTS]u8 = @splat(0);
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
        if (input.object.get("priorities")) |parr| {
            if (parr == .array) {
                for (parr.array.items, 0..) |it, i| {
                    if (i >= MAX_SUBAGENTS) break;
                    if (it == .integer) prios_buf[i] = @intCast(std.math.clamp(it.integer, 0, 255));
                }
            }
        }
    }
    if (tasks.items.len == 0) {
        return registry.ToolResult{ .output = "Missing field: tasks (array of task descriptions)", .is_error = true };
    }
    const n = @min(tasks.items.len, MAX_SUBAGENTS);

    const jobs = try alloc.create([MAX_SUBAGENTS]AgentJob);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        jobs[i] = .{ .ctx = ctx, .task_text = try ctx.alloc.dupe(u8, tasks.items[i]) };
    }

    // Claim order: priority-descending, STABLE (equal priorities keep the
    // task order — n <= 3 so a tiny insertion sort beats std.sort).
    var order: [MAX_SUBAGENTS]usize = undefined;
    for (0..n) |k| order[k] = k;
    var k: usize = 1;
    while (k < n) : (k += 1) {
        const v = order[k];
        var j = k;
        while (j > 0 and prios_buf[order[j - 1]] < prios_buf[v]) : (j -= 1) order[j] = order[j - 1];
        order[j] = v;
    }

    var wctx = WorkerCtx{
        .ctx = ctx,
        .jobs = jobs,
        .order = order,
        .order_len = n,
        .next = std.atomic.Value(u32).init(0),
    };

    // P3 cancel: during a dispatch the terminal is in COOKED mode with
    // ISIG on, so Ctrl-C arrives as a real SIGINT — route it to the
    // cooperative flag instead of killing the session. Restored after.
    const int_act: std.posix.Sigaction = .{
        .handler = .{ .handler = onDispatchSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &int_act, &old_int);
    active_cancel = &wctx.cancel;
    defer {
        active_cancel = null;
        std.posix.sigaction(.INT, &old_int, null);
    }

    const conc = @min(@as(usize, @max(ctx.concurrency.*, 1)), n);
    var threads: [MAX_SUBAGENTS - 1]?std.Thread = @splat(null);
    var spawned: usize = 0;
    while (spawned < conc - 1) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, workerMain, .{&wctx}) catch break;
    }
    workerMain(&wctx); // the calling thread is the last worker
    for (threads[0..spawned]) |t| t.?.join();

    const canceled = wctx.cancel.load(.acquire);
    if (ctx.bus) |b| {
        var ok_jobs: u8 = 0;
        var fail_jobs: u8 = 0;
        for (jobs[0..n]) |*j| {
            if (j.result != null) ok_jobs += 1 else fail_jobs += 1;
        }
        if (fail_jobs == 0) {
            b.emit(.{ .task_completed = .{ .jobs = ok_jobs } });
        } else {
            b.emit(.{ .task_failed = .{ .ok = ok_jobs, .failed = fail_jobs } });
        }
    }
    const tr = try mergeJobs(alloc, ctx, jobs, n, canceled);
    alloc.destroy(jobs);
    return tr;
}

const WorkerCtx = struct {
    ctx: *DispatchCtx,
    jobs: *[MAX_SUBAGENTS]AgentJob,
    order: [MAX_SUBAGENTS]usize,
    order_len: usize,
    next: std.atomic.Value(u32),
    /// P3 cooperative cancel — set by the dispatch SIGINT handler; checked
    /// before claiming a job and inside the subagent every turn/tool.
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Active dispatch cancel flag for the SIGINT handler (async-signal-safe:
/// the handler only does an atomic store). Null outside a dispatch, where
/// SIGINT keeps its default disposition.
var active_cancel: ?*std.atomic.Value(bool) = null;

fn onDispatchSigint(_: std.posix.SIG) callconv(.c) void {
    if (active_cancel) |c| c.store(true, .release);
}

/// One worker: private io + provider created AND destroyed on THIS thread
/// (B-pattern, same as the background reflection worker), reused across
/// every job it claims.
fn workerMain(w: *WorkerCtx) void {
    var io_state = std.Io.Threaded.init(w.ctx.alloc, .{});
    defer io_state.deinit();
    const wio = io_state.io();
    var storage: ProviderStorage = undefined;
    const provider = makeProviderInto(w.ctx, wio, &storage);
    defer provider.deinit();
    while (true) {
        if (w.cancel.load(.acquire)) break;
        const c = w.next.fetchAdd(1, .monotonic);
        if (c >= w.order_len) break;
        const idx = w.order[c];
        runJob(w, idx, provider, wio);
    }
}

fn runJob(w: *WorkerCtx, idx: usize, provider: llm.Provider, wio: std.Io) void {
    const res = subagent.run(.{
        .task = w.jobs[idx].task_text,
        .alloc = w.ctx.alloc,
        .io = wio,
        .provider = provider,
        .tools = w.ctx.tools,
        .cancel = &w.cancel,
        .progress = &w.jobs[idx].progress,
    });
    finishJob(&w.jobs[idx], res);
    // P3 retry: fail-FAST jobs (≤3 turns in) get exactly one 1s-backoff
    // retry — the P1 watchdog converts gateway stalls into exactly this
    // failure class. Jobs that already made real progress keep their
    // failure: rerunning from zero would just double the bill.
    if (w.jobs[idx].failed and !w.jobs[idx].retried and
        w.jobs[idx].failed_turns <= 3 and !w.cancel.load(.acquire))
    {
        w.jobs[idx].retried = true;
        var ts: std.c.timespec = .{ .sec = 1, .nsec = 0 };
        _ = std.c.nanosleep(&ts, null);
        const res2 = subagent.run(.{
            .task = w.jobs[idx].task_text,
            .alloc = w.ctx.alloc,
            .io = wio,
            .provider = provider,
            .tools = w.ctx.tools,
            .cancel = &w.cancel,
            .progress = &w.jobs[idx].progress,
        });
        finishJob(&w.jobs[idx], res2);
    }
}

fn finishJob(job: *AgentJob, res: subagent.SubagentResult) void {
    job.result = res;
    if (std.mem.startsWith(u8, res.summary, "subagent failed")) {
        job.failed = true;
        job.failed_turns = res.turns_used;
        res.deinit(job.ctx.alloc);
        job.result = null;
    }
}

/// T6.5: merge — each summary capped at ~500 tokens with per-agent stats.
/// Frees job payloads; the arrays themselves are freed by the caller.
fn mergeJobs(alloc: std.mem.Allocator, ctx: *DispatchCtx, jobs: *[MAX_SUBAGENTS]AgentJob, n: usize, canceled: bool) !registry.ToolResult {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    if (canceled) try w.writeAll("(已按 Ctrl-C 取消：未完成的子任务被中断)\n");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        defer if (jobs[i].result) |r| r.deinit(ctx.alloc);
        defer ctx.alloc.free(jobs[i].task_text);
        try w.print("## 子任务 {d}\n", .{i + 1});
        if (jobs[i].result) |r| {
            const cut = subagent.utf8TokenCut(r.summary, SUMMARY_TOKEN_CAP);
            try w.print("{s}\n(轮次 {d} · 工具调用 {d} · tokens {d}/{d})\n", .{ cut, r.turns_used, r.tool_calls, r.tokens_in, r.tokens_out });
            if (cut.len < r.summary.len) try w.writeAll("(截断)\n");
        } else if (jobs[i].failed) {
            try w.writeAll("(子代理执行失败)\n");
        } else {
            try w.writeAll("(仍在运行——超时放弃等待)\n");
        }
    }
    var list = aw.toArrayList();
    return registry.ToolResult{ .output = try list.toOwnedSlice(alloc) };
}

/// Provider STORAGE (probe-crash root cause): OpenAIProvider.init returns
/// a VALUE whose toProvider() points at itself — storing that value on
/// makeProvider's stack and returning the type-erased Provider dangles
/// (0xAA poison crash under Debug). Callers own the storage; this union
/// holds any backend's concrete provider.
pub const ProviderStorage = union(llm.BackendType) {
    openai: openai.OpenAIProvider,
    claude: claude.ClaudeProvider,
    ollama: ollama.OllamaProvider,

    pub fn provider(self: *ProviderStorage) llm.Provider {
        return switch (self.*) {
            inline else => |*p| p.toProvider(),
        };
    }
};

/// Build a provider INTO caller-owned storage; the returned Provider is
/// valid as long as `storage` lives.
fn makeProviderInto(ctx: *DispatchCtx, job_io: std.Io, storage: *ProviderStorage) llm.Provider {
    switch (ctx.backend) {
        .openai => storage.* = .{ .openai = openai.OpenAIProvider.init(ctx.alloc, job_io, .{
            .api_key = ctx.api_key orelse "",
            .model = ctx.model,
            .base_url = ctx.base_url orelse "https://api.openai.com/v1",
        }) },
        .claude => storage.* = .{ .claude = claude.ClaudeProvider.init(ctx.alloc, job_io, .{
            .api_key = ctx.api_key orelse "",
            .model = ctx.model,
            .base_url = ctx.base_url orelse "https://api.anthropic.com",
        }) },
        .ollama => storage.* = .{ .ollama = ollama.OllamaProvider.init(ctx.alloc, job_io, .{
            .model = ctx.model,
            .base_url = ctx.ollama_host,
        }) },
    }
    return storage.provider();
}

test "dispatch constants stay bounded" {
    try std.testing.expectEqual(@as(usize, 3), MAX_SUBAGENTS);
    try std.testing.expect(SUMMARY_TOKEN_CAP == 500);
}

test "claim order: priority descending, stable within equals" {
    // Mirrors the insertion-sort inline in executeWithCtx.
    const prios = [_]u8{ 1, 5, 3 };
    var order: [3]usize = .{ 0, 1, 2 };
    var k: usize = 1;
    while (k < 3) : (k += 1) {
        const v = order[k];
        var j = k;
        while (j > 0 and prios[order[j - 1]] < prios[v]) : (j -= 1) order[j] = order[j - 1];
        order[j] = v;
    }
    // p1 (5) first, then p3 (3), then p0 (1)
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &order);

    // equal priorities keep original order (stability)
    const eq = [_]u8{ 2, 2, 2 };
    var order2: [3]usize = .{ 0, 1, 2 };
    k = 1;
    while (k < 3) : (k += 1) {
        const v = order2[k];
        var j = k;
        while (j > 0 and eq[order2[j - 1]] < eq[v]) : (j -= 1) order2[j] = order2[j - 1];
        order2[j] = v;
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &order2);
}
