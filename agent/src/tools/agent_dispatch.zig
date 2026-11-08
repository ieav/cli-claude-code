/// Agent dispatch tool (T6.3-T6.5, P2 re-opened T6.4) — parallel subagent
/// fan-out. The MAIN agent spawns up to 10 focused subagents
/// (agent/subagent.zig) and gets their merged reports. Default semantics
/// stay READ-ONLY (no write param); `write:true` grants FULL permissions
/// through the caller's real rules — ask-tier calls still denied (headless
/// discipline), and write dispatches run SERIALLY (parallel agents editing
/// the same file lose updates; serial is the simplest correct v1).
/// Concurrency is configurable (settings.subagent_concurrency, default 4,
/// clamp 1..10); each worker thread owns a PRIVATE Io.Threaded + provider
/// (B-pattern — sharing the main loop's io across threads is unsafe at the
/// std layer) and claims jobs through a shared atomic index in
/// priority-descending order. The calling thread joins the worker pool;
/// spawn failures degrade to fewer workers, never to a hang (the P1 stall
/// watchdog caps every request).
const std = @import("std");
const registry = @import("registry.zig");
const runtime_registry = @import("runtime_registry.zig");
const llm = @import("../llm/mod.zig");
const subagent = @import("../agent/subagent.zig");
const tokens = @import("../util/tokens.zig");
const event_bus = @import("../task/event_bus.zig");
const cancel_mod = @import("../util/cancel.zig");
const openai = @import("../llm/openai.zig");
const claude = @import("../llm/claude.zig");
const ollama = @import("../llm/ollama.zig");

pub const MAX_SUBAGENTS: usize = 10;
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
    /// M4 fork：父会话历史（dispatch 期间主线程阻塞在本工具里，历史
    /// 稳定，只读借用安全）。null = fork 不可用（REPL 未接线）。
    history: ?*const std.ArrayList(llm.Message) = null,
    /// 全能力素材（write:true 时组 PermissionsContext 注入子代理）。
    /// mode 用指针——/mode 热切换对下一次 dispatch 生效；规则切片指
    /// 向 switcher.settings（retired 不释放，生命周期安全）。null =
    /// REPL 未接线 → write 请求静默降级为只读。
    perm_mode: ?*const registry.PermissionMode = null,
    allow_rules: []const registry.PermissionRule = &.{},
    deny_rules: []const registry.PermissionRule = &.{},
    ask_rules: []const registry.PermissionRule = &.{},
};

/// M4 fork 继承的 token 帽：父历史只取尾部（最新上下文最相关，
/// 且控制子代理首请求体量）。
pub const FORK_TOKEN_CAP: u32 = 16_000;

/// 从尾部往前取 ≤cap tokens 的连续切片（跳过 index 0 的 system——
/// 子代理有自己的 system prompt，避免双 system）。
pub fn forkTail(messages: []const llm.Message, cap: u32) []const llm.Message {
    if (messages.len <= 1) return &.{};
    var acc: u32 = 0;
    var start = messages.len;
    while (start > 1) {
        start -= 1;
        acc += messageTokens(messages[start]);
        if (acc > cap) {
            start += 1; // 超帽的最后一条退回
            break;
        }
    }
    if (start < 1) start = 1;
    if (start >= messages.len) return &.{};
    return messages[start..];
}

/// 单消息 token 估算（块级求和；tool_use 参数 DOM 不展开按次计）。
fn messageTokens(m: llm.Message) u32 {
    var acc: u32 = 0;
    for (m.content) |b| switch (b) {
        .text => |t| acc += tokens.estimateTokens(t),
        .tool_result => |tr| acc += tokens.estimateTokens(tr.content),
        .tool_use => acc += 64,
        else => {},
    };
    return acc;
}

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
    /// M4：本 job 的工具白名单（null=全量）与 fork 继承切片（空=不继承）。
    allowed_tools: ?[]const []const u8 = null,
    inherited: []const llm.Message = &.{},
    max_turns: usize = subagent.MAX_TURNS,
    /// 实时观测（2026-11-09）：UI 状态行读 progress/finished 都是原子，
    /// 主线程渲染与 worker 写入无数据竞争；result 本体仍只归 worker。
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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

    // M4 参数：tools 白名单（只能收窄）/ fork 继承 / max_turns。
    // 全能力（write:true）：经调用方真实权限规则放行——ask 档在无头
    // 环境仍然拒绝（与 -p 同语义）；deny/allow/bypass/dont_ask 照常
    // 生效。写型 dispatch 强制串行（并行子代理改同一文件会丢更新）。
    var allowed: ?[]const []const u8 = null;
    var fork = false;
    var write = false;
    var max_turns: usize = subagent.MAX_TURNS;
    if (input == .object) {
        if (input.object.get("tools")) |tarr| {
            if (tarr == .array and tarr.array.items.len > 0) {
                var list: std.ArrayList([]const u8) = .empty;
                for (tarr.array.items) |it| {
                    if (it == .string) try list.append(alloc, it.string);
                }
                if (list.items.len > 0) allowed = try list.toOwnedSlice(alloc);
            }
        }
        if (input.object.get("fork")) |f| {
            if (f == .bool) fork = f.bool;
        }
        if (input.object.get("write")) |wt| {
            if (wt == .bool) write = wt.bool;
        }
        if (input.object.get("max_turns")) |mt| {
            if (mt == .integer and mt.integer >= 1) max_turns = @min(@as(usize, @intCast(mt.integer)), subagent.MAX_TURNS);
        }
    }

    // 组全能力权限上下文：auto 在子代理环境降级为 default（无头不做
    // LLM 分类审批——每次工具调用烧一轮 LLM 不划算，规则语义足够）。
    var perm_ctx_storage: ?registry.PermissionContext = null;
    if (write) {
        if (ctx.perm_mode) |mp| {
            var mode = mp.*;
            if (mode == .auto) mode = .default;
            perm_ctx_storage = .{
                .mode = mode,
                .allow_rules = ctx.allow_rules,
                .deny_rules = ctx.deny_rules,
                .ask_rules = ctx.ask_rules,
                .provider = null,
                .allocator = ctx.alloc,
                .model_name = ctx.model,
            };
        }
    }
    var inherited: []const llm.Message = &.{};
    if (fork) {
        if (ctx.history) |h| inherited = forkTail(h.items, FORK_TOKEN_CAP);
    }
    // 审查 B 项：白名单切片本体在 merge 后释放（字符串借用自输入 DOM，
    // 只释放数组）。放 defer 保证所有 return 路径都覆盖——workers 在
    // mergeJobs 返回前全部 join，此刻无并发读者。
    defer if (allowed) |a| alloc.free(a);

    const jobs = try alloc.create([MAX_SUBAGENTS]AgentJob);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        jobs[i] = .{
            .ctx = ctx,
            .task_text = try ctx.alloc.dupe(u8, tasks.items[i]),
            .allowed_tools = allowed,
            .inherited = inherited,
            .max_turns = max_turns,
        };
    }

    // Claim order: priority-descending, STABLE (equal priorities keep the
    // task order — n <= 10, a tiny insertion sort beats std.sort).
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
        .perm_ctx = if (perm_ctx_storage) |*pc| pc else null,
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

    // 写型 dispatch 一律串行：并发只给只读研究型 fan-out。
    const conc = if (perm_ctx_storage != null) 1 else @min(@as(usize, @max(ctx.concurrency.*, 1)), n);
    var threads: [MAX_SUBAGENTS - 1]?std.Thread = @splat(null);
    var spawned: usize = 0;
    while (spawned < conc - 1) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, workerMain, .{&wctx}) catch break;
    }
    live_dispatch = &wctx; // UI 泵从这刻起可渲染子代理实时进度
    workerMain(&wctx); // the calling thread is the last worker
    for (threads[0..spawned]) |t| t.?.join();
    live_dispatch = null; // join 完即撤——jobs 将随本函数栈销毁

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
    // 超限任务必须可见：静默丢弃会让模型以为全部已派（容量升到 10 后
    // 这个坑从"理论"变"现实"）——拼一行提示让它分批。
    if (tasks.items.len > n) {
        const dropped = tasks.items.len - n;
        const note = std.fmt.allocPrint(alloc, "{s}\n(超出单次上限 {d}：后 {d} 个任务未执行——请分批派发)\n", .{ tr.output, MAX_SUBAGENTS, dropped }) catch return tr;
        alloc.free(tr.output);
        return registry.ToolResult{ .output = note };
    }
    return tr;
}

const WorkerCtx = struct {
    ctx: *DispatchCtx,
    jobs: *[MAX_SUBAGENTS]AgentJob,
    order: [MAX_SUBAGENTS]usize,
    order_len: usize,
    next: std.atomic.Value(u32),
    /// 全能力权限上下文（dispatch 栈上，worker 借用——join 完才返回）。
    perm_ctx: ?*const registry.PermissionContext = null,
    /// P3 cooperative cancel — set by the dispatch SIGINT handler; checked
    /// before claiming a job and inside the subagent every turn/tool.
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Active dispatch cancel flag for the SIGINT handler (async-signal-safe:
/// the handler only does an atomic store). Null outside a dispatch, where
/// SIGINT keeps its default disposition.
var active_cancel: ?*std.atomic.Value(bool) = null;

/// 活跃 dispatch 的观测句柄（与 active_cancel 同生命周期）：REPL 工具
/// 相位的 UI 泵每 500ms 读 liveSummary 渲染子代理实时进度。jobs 栈上
/// 存活、join 后清空——UI 只在 tool_job.done 前读，无悬垂窗口。
var live_dispatch: ?*WorkerCtx = null;

/// 子代理实时进度行（写入 buf，返回切片；无活跃 dispatch → null）。
/// 只读原子量：progress（当前轮次）/ finished。最多列 6 个 + 省略号。
pub fn liveSummary(buf: []u8) ?[]const u8 {
    const wctx = live_dispatch orelse return null;
    var fbs = std.Io.Writer.fixed(buf);
    const w = &fbs;
    const shown = @min(wctx.order_len, 6);
    w.print("agent {d}/{d}：", .{ countDone(wctx), wctx.order_len }) catch return null;
    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const j = &wctx.jobs[i];
        if (i > 0) w.writeAll(" · ") catch break;
        if (j.finished.load(.acquire)) {
            w.print("#{d} ✓", .{i + 1}) catch break;
        } else {
            w.print("#{d} t{d}", .{ i + 1, j.progress.load(.acquire) }) catch break;
        }
    }
    if (wctx.order_len > shown) w.writeAll(" · …") catch {};
    return buf[0..w.end];
}

fn countDone(wctx: *WorkerCtx) usize {
    var n: usize = 0;
    for (wctx.jobs[0..wctx.order_len]) |*j| {
        if (j.finished.load(.acquire)) n += 1;
    }
    return n;
}

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
        // Esc-during-tools cancels the batch (util/cancel.tool_batch_cancel):
        // bridge it into THIS dispatch's cooperative flag so in-flight
        // subagents (which poll it every turn/tool) stop too, not just the
        // not-yet-claimed jobs.
        if (cancel_mod.toolBatchCancelled()) w.cancel.store(true, .release);
        if (w.cancel.load(.acquire)) break;
        const c = w.next.fetchAdd(1, .monotonic);
        if (c >= w.order_len) break;
        const idx = w.order[c];
        runJob(w, idx, provider, wio);
    }
}

fn runJob(w: *WorkerCtx, idx: usize, provider: llm.Provider, wio: std.Io) void {
    const job = &w.jobs[idx];
    const res = subagent.run(.{
        .task = job.task_text,
        .alloc = w.ctx.alloc,
        .io = wio,
        .provider = provider,
        .tools = w.ctx.tools,
        .cancel = &w.cancel,
        .progress = &job.progress,
        .allowed_tools = job.allowed_tools,
        .inherited = if (job.inherited.len > 0) job.inherited else null,
        .max_turns = job.max_turns,
        .perm_ctx = w.perm_ctx,
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
            .task = job.task_text,
            .alloc = w.ctx.alloc,
            .io = wio,
            .provider = provider,
            .tools = w.ctx.tools,
            .cancel = &w.cancel,
            .progress = &job.progress,
            .allowed_tools = job.allowed_tools,
            .inherited = if (job.inherited.len > 0) job.inherited else null,
            .max_turns = job.max_turns,
            .perm_ctx = w.perm_ctx,
        });
        finishJob(&w.jobs[idx], res2);
    }
}

fn finishJob(job: *AgentJob, res: subagent.SubagentResult) void {
    job.finished.store(true, .release);
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
    if (canceled) try w.writeAll("(已按用户中断取消：未完成的子任务被中断)\n");
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

test "forkTail: tail slice, skips system, honors cap (M4)" {
    const a = std.testing.allocator;
    const mkMsg = struct {
        fn mk(al: std.mem.Allocator, text: []const u8) llm.Message {
            const b = al.alloc(llm.ContentBlock, 1) catch unreachable;
            b[0] = .{ .text = @constCast(text) };
            return .{ .role = .user, .content = b, .timestamp = 0 };
        }
    }.mk;
    var msgs: std.ArrayList(llm.Message) = .empty;
    defer {
        for (msgs.items) |m| a.free(m.content);
        msgs.deinit(a);
    }
    try msgs.append(a, mkMsg(a, "SYSTEM")); // index 0 — 永不继承
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try msgs.append(a, mkMsg(a, "padding message body text for cap estimation"));
    }
    // 大帽：继承除 system 外全部。
    const full = forkTail(msgs.items, 1_000_000);
    try std.testing.expectEqual(msgs.items.len - 1, full.len);
    // 小帽：只留尾部若干条，且不包含 system。
    const small = forkTail(msgs.items, 30);
    try std.testing.expect(small.len > 0 and small.len < full.len);
    try std.testing.expect(!std.mem.eql(u8, small[0].content[0].text, "SYSTEM"));
    // 单条就超帽 → 空。
    try std.testing.expectEqual(@as(usize, 0), forkTail(msgs.items, 1).len);
    // 只剩 system → 空。
    const only_sys = [_]llm.Message{msgs.items[0]};
    try std.testing.expectEqual(@as(usize, 0), forkTail(&only_sys, 1_000_000).len);
}

test "dispatch constants stay bounded" {
    // 2026-11-08 容量 3→10（全能力多 agent 需求）；10 也是网关限流
    // 面的合理上界——20 路并发 LLM 流必撞 429。
    try std.testing.expectEqual(@as(usize, 10), MAX_SUBAGENTS);
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

test "liveSummary renders per-subagent progress from atomics only" {
    // 模拟一个 3 任务 dispatch：#1 完成、#2 跑到 t4、#3 未开始。
    var jobs: [MAX_SUBAGENTS]AgentJob = undefined;
    for (&jobs) |*j| j.* = .{ .ctx = undefined, .task_text = @constCast("t") };
    jobs[0].finished.store(true, .release);
    jobs[1].progress.store(4, .release);
    var wctx = WorkerCtx{
        .ctx = undefined,
        .jobs = &jobs,
        .order = undefined,
        .order_len = 3,
        .next = std.atomic.Value(u32).init(0),
    };
    live_dispatch = &wctx;
    defer live_dispatch = null;
    var buf: [128]u8 = undefined;
    const s = liveSummary(&buf) orelse return error.NoSummary;
    try std.testing.expect(std.mem.indexOf(u8, s, "agent 1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "#1 ✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "#2 t4") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "#3 t0") != null);
    // 无活跃 dispatch → null（UI 回落泛化状态行）。
    live_dispatch = null;
    try std.testing.expect(liveSummary(&buf) == null);
}
