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

    // Heap jobs: uniform cleanup (merge frees payloads, destroy frees the
    // array) regardless of how many tasks ran.
    const jobs = try alloc.create([MAX_SUBAGENTS]AgentJob);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        jobs[i] = .{ .ctx = ctx, .task_text = try ctx.alloc.dupe(u8, tasks.items[i]) };
    }

    // T6.4 (settled): subagents run SERIALLY, each on the calling thread
    // with a private provider in caller-owned storage. Root causes found
    // and fixed along the way: (1) makeProvider used to return providers
    // pointing into its own dead stack frame (0xAA crash — the original
    // "hang"), now ProviderStorage outlives use; (2) multi-thread provider
    // use is unsafe at the std layer (http CA lock futexes through the
    // constructing io; separate Io.Threaded instances corrupt some global
    // state — main-thread writes hung after a broker run). Serial + fixed
    // storage is the configuration this codebase can PROVE stable.
    i = 0;
    while (i < n) : (i += 1) {
        var storage: ProviderStorage = undefined;
        const provider = makeProviderInto(ctx, ctx.io, &storage);
        defer provider.deinit();
        const res = subagent.run(.{
            .task = jobs[i].task_text,
            .alloc = ctx.alloc,
            .io = ctx.io,
            .provider = provider,
            .tools = ctx.tools,
        });
        finishJob(&jobs[i], res);
    }
    const tr = try mergeJobs(alloc, ctx, jobs, n);
    alloc.destroy(jobs);
    return tr;
}

fn finishJob(job: *AgentJob, res: subagent.SubagentResult) void {
    job.result = res;
    if (std.mem.startsWith(u8, res.summary, "subagent failed")) {
        job.failed = true;
        res.deinit(job.ctx.alloc);
        job.result = null;
    }
}

/// T6.5: merge — each summary capped at ~500 tokens with per-agent stats.
/// Frees job payloads; the arrays themselves are freed by the caller.
fn mergeJobs(alloc: std.mem.Allocator, ctx: *DispatchCtx, jobs: *[MAX_SUBAGENTS]AgentJob, n: usize) !registry.ToolResult {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    var i: usize = 0;
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
