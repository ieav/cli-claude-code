/// Headless subagent runner (T6.1/T6.2) — a complete agent loop without
/// the REPL: no UI, no prompt, no memory blocks. Reuses the tool registry,
/// the provider layer and the permission pipeline; safety comes from the
/// whitelist + Default-mode semantics (read-only tools pass, anything that
/// would ASK in interactive mode is auto-DENIED here).
///
/// Concurrency (T6.4): safe to run on pool workers — every input it reads
/// (task text, tool specs, provider, config) is either passed by value or
/// read-only after REPL init; the permission context uses EMPTY rule sets
/// so it never races a settings hot-reload.
const std = @import("std");
const llm = @import("../llm/mod.zig");
const compaction = @import("../llm/compaction.zig");
const registry = @import("../tools/registry.zig");
const runtime_registry = @import("../tools/runtime_registry.zig");
const auth = @import("../tools/auth_mode.zig");
const hooks_mod = @import("../hooks/hooks.zig");

/// F4a（2026-11-15）：10→16。委派的编码任务（读 N 文件 + grep + 写 + 验
/// 证）在 10 轮内经常做不完——触顶即半途而废（#4 修复保住了报告，任务
/// 本身仍截断）。16 是单子代理成本上限与完成率的折中；取消、进度观测、
/// fail-fast 重试等护栏不变。oneshot（-p）不受此值约束（走
/// settings.agent_loop_limit）。
pub const MAX_TURNS: usize = 16;

/// Tools a subagent may never see: session-scoped task tracking and
/// interactive questions make no sense without the REPL around them.
/// Names are the registry's canonical ones — "AskUserQuestion", NOT the
/// "AskUser" shorthand (exact-match deny let the real tool slip through
/// until 2026-11-10). DirTree/Glob/Grep etc. stay VISIBLE — read-only
/// reconnaissance is exactly what research fan-outs are for.
const deny_tools = [_][]const u8{ "TaskCreate", "TaskList", "TaskUpdate", "TaskGet", "AskUserQuestion", "BgTask", "agent", "plan_approve", "ScheduleWakeup" };

fn toolAllowed(name: []const u8) bool {
    for (deny_tools) |d| {
        if (std.mem.eql(u8, name, d)) return false;
    }
    return true;
}

/// M4：dispatch 传入的工具白名单之上再收一层（null = 全量可见）。
/// 白名单只能收窄不能放宽——deny_tools 与只读权限语义不变。
pub fn toolVisible(name: []const u8, allowed: ?[]const []const u8) bool {
    if (!toolAllowed(name)) return false;
    const list = allowed orelse return true;
    for (list) |a| {
        if (std.mem.eql(u8, name, a)) return true;
    }
    return false;
}

/// One subagent's run configuration. Providers are always single-thread
/// owned (see agent_dispatch.ProviderStorage for why sharing is unsafe:
/// std.http's CA-bundle lock futexes through the constructing io).
pub const SubagentConfig = struct {
    task: []const u8,
    alloc: std.mem.Allocator,
    io: std.Io,
    provider: llm.Provider,
    tools: *runtime_registry.RuntimeRegistry,
    /// Hard turn cap; the caller may lower it further.
    max_turns: usize = MAX_TURNS,
    /// P3 cooperative cancel: checked before every LLM turn and every
    /// tool call — a canceled subagent exits with "(canceled...)" instead
    /// of burning the remaining turns.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// P3 progress: the current turn number (1..max_turns), stored before
    /// each LLM call so a dispatcher can observe live progress.
    progress: ?*std.atomic.Value(u32) = null,
    /// M4 工具清单：本子代理可见的工具名（null = 继承全部再走 deny 过滤）。
    /// 只能收窄——权限语义（只读 + ask 自动拒）不变。
    allowed_tools: ?[]const []const u8 = null,
    /// M4 fork：继承的父会话消息（只读借用——主线程阻塞在 dispatch 里，
    /// 期间不会变更；块永不单独释放，借用安全）。种子顺序：
    /// 子代理 system → 继承消息 → 任务。
    inherited: ?[]const llm.Message = null,
    /// M7 -p：覆盖系统提示（null = 子代理默认 headless 提示）。oneshot
    /// 传 ziv 正式 system prompt，让两种入口共享同一份人设。
    system_prompt: ?[]const u8 = null,
    /// M7 -p：覆盖权限上下文（null = 空规则 + Default 的子代理只读语
    /// 义）。oneshot 传用户 settings 的规则与模式——ask 决策在无头环境
    /// 仍然降级为拒绝（无人在场，不允许悬停等待）。
    perm_ctx: ?*const registry.PermissionContext = null,
    /// 每轮 LLM 输出预算（token）。默认值只是兜底——调用方应传"与主
    /// 会话同源"的预算（settings.max_tokens）：思考型模型的思考 token
    /// 计入输出预算，2048 级硬编码会让思考模型"想完就没字了"（主循环
    /// 同因已默认 16384，见 config.zig max_tokens 注释）。dispatch 与
    /// oneshot 都从各自的 settings 接线。
    response_budget: u32 = 4096,
    /// F4b（2026-11-15）：上下文窗口估算（tokens），驱动应急折叠阈值。
    /// 调用方应传 provider.contextEstimate(model, backend)（用户有
    /// settings.context_window 覆盖时传覆盖值）；0 = 按 32K 保守处理。
    /// 子代理循环没有主循环的压缩基建——10+ 轮大结果累积会把小窗模型
    /// 顶爆（400 = 整任务失败，fail-fast 重试再原样爆一遍）。
    context_ceiling: u32 = 0,
};

pub const SubagentResult = struct {
    /// Final assistant text (allocator-owned by cfg.alloc).
    summary: []u8,
    turns_used: usize,
    tool_calls: usize,
    /// Cumulative LLM usage across all turns (T6.6 metering — the merge
    /// report surfaces these so a fan-out's cost is visible, not felt).
    tokens_in: u32 = 0,
    tokens_out: u32 = 0,
    /// M7 -p：runInner 出错（provider 不可达等）。summary 已是错误文本；
    /// 该标志让 oneshot 能区分「答案」与「失败」，给 CI 正确的退出码。
    err: bool = false,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.summary);
    }
};

const headless_system_prompt =
    \\You are a focused subagent. Complete the assigned task with the tools
    \\available, then reply with a concise result (what you found / did,
    \\key file paths, and anything the caller must know). You have no
    \\access to task tracking or user questions — work autonomously and
    \\report at the end. You are READ-ONLY: if a tool call is denied by
    \\permissions, do NOT retry the same kind of operation — switch to a
    \\different allowed approach or report the denial as your result.
;

/// Run one subagent to completion. Errors are folded into the summary so
/// the caller always gets printable text.
pub fn run(cfg: SubagentConfig) SubagentResult {
    var err_buf: ?[]u8 = null;
    const res = runInner(cfg) catch |e| blk: {
        err_buf = std.fmt.allocPrint(cfg.alloc, "subagent failed: {s}", .{@errorName(e)}) catch null;
        break :blk SubagentResult{ .summary = err_buf.?, .turns_used = 0, .tool_calls = 0, .err = true };
    };
    if (err_buf != null) return res; // summary already the error text
    return res;
}

fn runInner(cfg: SubagentConfig) !SubagentResult {
    // F4b：应急折叠的窗口口径（0 → 32K 保守默认）。
    const ctx_ceiling: usize = if (cfg.context_ceiling > 0) cfg.context_ceiling else 32_768;
    const alloc = cfg.alloc;

    // Whitelisted tool specs (T6.2; M4 再叠 dispatch 传入的白名单).
    var specs: std.ArrayList(llm.ToolSpec) = .empty;
    defer specs.deinit(alloc);
    for (cfg.tools.definitions()) |*def| {
        if (!toolVisible(def.name, cfg.allowed_tools)) continue;
        // Registry fields are static strings — a plain borrow is safe.
        try specs.append(alloc, .{
            .name = def.name,
            .description = def.description,
            .input_schema = def.input_schema,
        });
    }

    // Per-turn heap: everything that must outlive one loop iteration
    // (assistant tool_use blocks, tool_result texts) lives here and is
    // freed together at the end — tool_use.input slices stay valid because
    // response DOMs are never freed inside the loop either.
    var block_arena = std.heap.ArenaAllocator.init(alloc);
    defer block_arena.deinit();
    const ba = block_arena.allocator();
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(alloc); // blocks live in the arena, freed above
    // system (+ fork 继承) + task
    {
        const sb = try ba.alloc(llm.ContentBlock, 1);
        sb[0] = .{ .text = cfg.system_prompt orelse headless_system_prompt };
        try history.append(alloc, .{ .role = .system, .content = sb, .timestamp = 0 });
        if (cfg.inherited) |inh| {
            // 借用块：只追加、永不单独释放（arena 只管新块）——安全。
            for (inh) |m| try history.append(alloc, .{ .role = m.role, .content = m.content, .timestamp = m.timestamp });
        }
        const ub = try ba.alloc(llm.ContentBlock, 1);
        ub[0] = .{ .text = cfg.task };
        try history.append(alloc, .{ .role = .user, .content = ub, .timestamp = 0 });
    }
    // F4b 修复（闭环审计 2026-11-15）：种子段（system + fork 借用 + 任务）
    // 与父会话共享 content 切片——「只追加、永不单独释放」契约。应急折叠
    // 只允许作用于本子代理自产的消息（own_start 起）；字节量统计仍含借用
    // 段（它们同样占窗口），但折叠绝不触碰。
    const own_start = history.items.len;

    var turn: usize = 0;
    var tool_calls: usize = 0;
    var tokens_in: u32 = 0;
    var tokens_out: u32 = 0;
    // fix #4（2026-11-15 大批量准确度）：跨轮跟踪最近一次非空 assistant
    // 文本。触顶 MAX_TURNS 的退出路径原先只回 "(turn limit reached)"——
    // 全部工作成果（改了什么、走到哪一步）随 arena 一起蒸发，主 agent
    // 无从核对，轻则重做重则覆盖冲突。现在它成为兜底摘要。
    var last_text: ?[]u8 = null;
    defer if (last_text) |lt| alloc.free(lt);
    while (turn < cfg.max_turns) : (turn += 1) {
        if (cfg.cancel) |c| {
            if (c.load(.acquire)) {
                return .{ .summary = try alloc.dupe(u8, "(canceled by user)"), .turns_used = turn + 1, .tool_calls = tool_calls, .tokens_in = tokens_in, .tokens_out = tokens_out };
            }
        }
        if (cfg.progress) |p| p.store(@intCast(turn + 1), .release);
        // F4b：超阈值应急折叠（≈70% 窗口，bytes≈tokens×3 与
        // compaction.messageTokens 同口径）。保最近 3 条结果原文，更早的
        // 大结果换标记——只动 content 不动 id/name/role，配对完整性天然
        // 保持。轻量、无 LLM、可重复触发（标记行低于 min_bytes 不再命中）。
        // 阈值按全量字节（借用段也占窗），折叠只落 own_start 起的自产段。
        if (historyBytes(history.items) > ctx_ceiling * 3 * 7 / 10) {
            _ = foldStaleResults(history.items[own_start..], alloc, 3, 256);
        }
        // In-flight cancellation: the cancel flag rides into the request
        // (watchdog-killed socket → error.EscCancelled) so an Esc'd
        // dispatch stops a BLOCKED complete within one 250ms tick instead
        // of waiting out the idle watchdog. Folded into the same
        // "(canceled by user)" result as the turn-boundary check.
        const resp = cfg.provider.complete(history.items, .{
            .max_tokens = cfg.response_budget,
            .tools = specs.items,
            .cancel_flag = cfg.cancel,
        }) catch |e| {
            if (e == error.EscCancelled) {
                return .{ .summary = try alloc.dupe(u8, "(canceled by user)"), .turns_used = turn + 1, .tool_calls = tool_calls, .tokens_in = tokens_in, .tokens_out = tokens_out };
            }
            return e;
        };
        tokens_in += resp.usage.input_tokens;
        tokens_out += resp.usage.output_tokens;
        // The response (and its DOM arena) is NEVER freed inside the loop:
        // tool_use.input slices live in it and outlive this turn inside
        // history. The process-level leak is bounded by max_turns and is
        // reclaimed when the subagent finishes (same trade as the
        // reflection timeout worker).
        // Copy out the final text (caller-owned, survives the run).
        var final_text: ?[]u8 = null;
        var tool_uses: std.ArrayList(llm.provider.ToolUseBlock) = .empty;
        defer tool_uses.deinit(alloc);
        for (resp.content) |b| switch (b) {
            .text => |t| {
                if (t.len == 0) continue;
                if (final_text == null) final_text = try alloc.dupe(u8, t);
                // Latest non-empty text across ALL turns (fix #4's raw
                // material for the turn-limit fallback summary).
                if (last_text) |lt| alloc.free(lt);
                last_text = try alloc.dupe(u8, t);
            },
            .tool_use => |tu| try tool_uses.append(alloc, tu), // DOM-backed: valid while the loop lives
            else => {},
        };

        if (tool_uses.items.len == 0) {
            const summary = final_text orelse try alloc.dupe(u8, "(no output)");
            return .{ .summary = summary, .turns_used = turn + 1, .tool_calls = tool_calls, .tokens_in = tokens_in, .tokens_out = tokens_out };
        }

        // Append the assistant turn (tool_use blocks), then results.
        const asst_blocks = try ba.alloc(llm.ContentBlock, tool_uses.items.len);
        for (tool_uses.items, 0..) |tu, i| asst_blocks[i] = .{ .tool_use = tu };
        try history.append(alloc, .{ .role = .assistant, .content = asst_blocks, .timestamp = 0 });

        for (tool_uses.items) |tu| {
            if (cfg.cancel) |c| {
                if (c.load(.acquire)) {
                    return .{ .summary = try alloc.dupe(u8, "(canceled by user)"), .turns_used = turn + 1, .tool_calls = tool_calls, .tokens_in = tokens_in, .tokens_out = tokens_out };
                }
            }
            tool_calls += 1;
            const out = executeWhitelisted(cfg, tu) catch |e| blk: {
                break :blk std.fmt.allocPrint(alloc, "tool error: {s}", .{@errorName(e)}) catch "tool error";
            };
            // fix #5（2026-11-15）：与主循环同一顶帽+截断标记。子代理的
            // 工具结果原先全文进历史——FileRead 一个大文件就让下一轮
            // complete() 超窗 400，整个任务失败，fail-fast 重试再原样爆
            // 一遍。帽子的 ptr 比较同时是「是否新分配」的判断：同一指
            // 针即原样借用（含 OOM 兜底字面量），新指针则旧串在此释放。
            const capped: []const u8 = try registry.capToolOutputForHistory(alloc, out);
            if (capped.ptr != out.ptr) alloc.free(out);
            // Execute results become the next user turn (single block per
            // call keeps the OpenAI tool-message mapping trivial).
            const rb = try ba.alloc(llm.ContentBlock, 1);
            rb[0] = .{ .tool_result = .{ .tool_use_id = ba.dupe(u8, tu.id) catch tu.id, .content = capped } };
            try history.append(alloc, .{ .role = .user, .content = rb, .timestamp = 0 });
        }
    }
    // 触顶退出（fix #4）：带上最后的 assistant 文本与工具量——报告的是
    // 「进行到这里」，不再是凭空蒸发。write 型 dispatch 的文件改动已落
    // 盘，这份兜底摘要是主 agent 核对产出的唯一线索。
    if (last_text) |lt| {
        const summary = try std.fmt.allocPrint(alloc, "(turn limit reached: {d} turns, {d} tool calls — last output below, work may be incomplete)\n{s}", .{ cfg.max_turns, tool_calls, lt });
        return .{ .summary = summary, .turns_used = cfg.max_turns, .tool_calls = tool_calls, .tokens_in = tokens_in, .tokens_out = tokens_out };
    }
    return .{ .summary = try alloc.dupe(u8, "(turn limit reached: no assistant text produced — work incomplete, nothing to report)"), .turns_used = cfg.max_turns, .tool_calls = tool_calls, .tokens_in = tokens_in, .tokens_out = tokens_out };
}

/// F4b（2026-11-15）：子代理历史字节量粗估——text/thinking/result 按
/// 字节，tool_use 按参数 DOM 字节（复用 compaction.jsonValueSize，同
/// 字节≈token/3 口径）。纯函数，可单测。
fn historyBytes(messages: []const llm.Message) usize {
    var n: usize = 0;
    for (messages) |m| {
        for (m.content) |b| switch (b) {
            .text => |t| n += t.len,
            .thinking => |t| n += t.len,
            .tool_result => |tr| n += tr.content.len,
            .tool_use => |tu| n += compaction.jsonValueSize(tu.input),
        };
    }
    return n;
}

/// F4b：超窗应急折叠——保留最近 `keep_results` 条工具结果原文，序数更
/// 早且 ≥min_bytes 的替换为标记行。块数组在 block_arena（不同分配器，
/// 不释放、随 arena 终结回收）；被替换的 content 为 cfg.alloc 所有
/// （executeWhitelisted 的全部产出路径均如此，字面量兜底短于 min_bytes
/// 永不命中），此处释放。返回折叠条数。消息数不变、id/name/role 不动
/// ——OpenAI wire 的 use/result 配对天然保持。
fn foldStaleResults(messages: []llm.Message, alloc: std.mem.Allocator, keep_results: usize, min_bytes: usize) usize {
    var total: usize = 0;
    for (messages) |m| for (m.content) |b| switch (b) {
        .tool_result => total += 1,
        else => {},
    };
    if (total <= keep_results) return 0;
    const fold_below = total - keep_results; // result 序数 0..fold_below-1 折叠

    var folded: usize = 0;
    var seen: usize = 0;
    for (messages) |*m| {
        // 本消息是否含要折的块（决定是否重建）。
        var res_n: usize = 0;
        var has_fold = false;
        for (m.content) |b| switch (b) {
            .tool_result => |tr| {
                if (seen + res_n < fold_below and tr.content.len >= min_bytes) has_fold = true;
                res_n += 1;
            },
            else => {},
        };
        const base = seen;
        seen += res_n;
        if (!has_fold) continue;

        const old = m.content;
        const nb = alloc.alloc(llm.ContentBlock, old.len) catch continue;
        var bi: usize = 0;
        var rord = base;
        for (old) |b| {
            if (b == .tool_result) {
                const is_stale = rord < fold_below and b.tool_result.content.len >= min_bytes;
                rord += 1;
                if (is_stale) {
                    const marker = std.fmt.allocPrint(alloc, "[旧输出已折叠（原 {d} B）· 需要原文请重新调用相应工具]", .{b.tool_result.content.len}) catch {
                        nb[bi] = b;
                        bi += 1;
                        continue;
                    };
                    nb[bi] = .{ .tool_result = .{
                        .tool_use_id = b.tool_result.tool_use_id,
                        .content = marker,
                        .is_error = b.tool_result.is_error,
                    } };
                    bi += 1;
                    folded += 1;
                    alloc.free(@constCast(b.tool_result.content)); // cfg.alloc 所有（见 doc 注释）
                    continue;
                }
            }
            nb[bi] = b;
            bi += 1;
        }
        // 旧块数组为 arena 所有，不释放（见 doc 注释）。
        m.content = nb[0..bi];
    }
    return folded;
}

test "foldStaleResults never touches the borrowed seed region (F4b closure fix)" {
    // 复刻 runInner 的种子结构：fork 借用消息与父会话共享 content 切片
    // （「只追加、永不单独释放」契约）。越界折叠会改写/释放父会话还在
    // 引用的字符串（UAF/双重释放）。锁定的契约：折叠只作用于
    // history.items[own_start..]——借用区字节原样、不出现折叠标记。
    var parent = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parent.deinit();
    const pa = parent.allocator();
    var own = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer own.deinit();
    const oa = own.allocator();

    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(std.testing.allocator);
    {
        const sb = try oa.alloc(llm.ContentBlock, 1);
        sb[0] = .{ .text = "SYSTEM" };
        try history.append(std.testing.allocator, .{ .role = .system, .content = sb, .timestamp = 0 });
        // 借用区：父会话拥有的 2 KiB 结果——超 min_bytes 的诱饵，若被
        // 折叠必现标记（断言即挂）。
        const bait = try pa.alloc(u8, 2048);
        @memset(bait, 'B');
        const borrowed_blocks = try pa.alloc(llm.ContentBlock, 1);
        borrowed_blocks[0] = .{ .tool_result = .{ .tool_use_id = "parent", .content = bait } };
        try history.append(std.testing.allocator, .{ .role = .user, .content = borrowed_blocks, .timestamp = 0 });
    }
    const own_start = history.items.len;
    // 自产区：5 条 2 KiB 结果（前 2 条应折，保最近 3 条）。
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const payload = try oa.alloc(u8, 2048);
        @memset(payload, 'o');
        const rb = try oa.alloc(llm.ContentBlock, 1);
        rb[0] = .{ .tool_result = .{ .tool_use_id = "own", .content = payload } };
        try history.append(std.testing.allocator, .{ .role = .user, .content = rb, .timestamp = 0 });
    }

    const folded = foldStaleResults(history.items[own_start..], oa, 3, 256);
    try std.testing.expectEqual(@as(usize, 2), folded);
    // 借用区：content 仍指向父会话的 bait，字节未动，无折叠标记。
    const borrowed = history.items[1].content[0].tool_result;
    try std.testing.expectEqual(@as(usize, 2048), borrowed.content.len);
    try std.testing.expect(std.mem.indexOf(u8, borrowed.content, "已折叠") == null);
    for (borrowed.content) |c| try std.testing.expectEqual(@as(u8, 'B'), c);
    // 自产区：前 2 条是标记，后 3 条原文。
    var markers: usize = 0;
    var kept: usize = 0;
    for (history.items[own_start..]) |m| for (m.content) |b| {
        if (b == .tool_result) {
            if (std.mem.indexOf(u8, b.tool_result.content, "已折叠") != null) markers += 1 else kept += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 2), markers);
    try std.testing.expectEqual(@as(usize, 3), kept);
}

test "historyBytes + foldStaleResults: stale results fold, pairing intact (F4b)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(std.testing.allocator);
    {
        const sb = try a.alloc(llm.ContentBlock, 1);
        sb[0] = .{ .text = "SYSTEM" };
        try history.append(std.testing.allocator, .{ .role = .system, .content = sb, .timestamp = 0 });
        const ub = try a.alloc(llm.ContentBlock, 1);
        ub[0] = .{ .text = "task" };
        try history.append(std.testing.allocator, .{ .role = .user, .content = ub, .timestamp = 0 });
    }
    // 6 条结果：前 3 条各 2 KiB（应折），后 3 条短小（保留原文）。
    // 内容用 cfg.alloc 语义（std.testing.allocator 之外的独立 arena 也
    // 行——fold 只释放被替换者，这里用同一 arena 则释放合法）。
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const payload = try a.alloc(u8, if (i < 3) 2048 else 32);
        @memset(payload, 'r');
        const rb = try a.alloc(llm.ContentBlock, 1);
        rb[0] = .{ .tool_result = .{ .tool_use_id = "t", .content = payload } };
        try history.append(std.testing.allocator, .{ .role = .user, .content = rb, .timestamp = 0 });
    }
    try std.testing.expect(historyBytes(history.items) > 3 * 2048);

    const folded = foldStaleResults(history.items, a, 3, 256);
    try std.testing.expectEqual(@as(usize, 3), folded);
    try std.testing.expectEqual(@as(usize, 8), history.items.len); // 消息数不变
    var markers: usize = 0;
    var kept: usize = 0;
    for (history.items[2..]) |m| for (m.content) |b| {
        if (b == .tool_result) {
            if (std.mem.indexOf(u8, b.tool_result.content, "已折叠") != null) markers += 1 else kept += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 3), markers);
    try std.testing.expectEqual(@as(usize, 3), kept);
    // 幂等：标记行低于 min_bytes，再次触发不再折。
    try std.testing.expectEqual(@as(usize, 0), foldStaleResults(history.items, a, 3, 256));
    // 结果数 ≤ keep 时零操作。
    var small: [2]llm.Message = undefined;
    small[0] = history.items[0];
    small[1] = history.items[1];
    try std.testing.expectEqual(@as(usize, 0), foldStaleResults(&small, a, 3, 256));
}

/// Deny-list + the CENTRAL permission pipeline (T6.2), then execute.
fn executeWhitelisted(cfg: SubagentConfig, tu: llm.provider.ToolUseBlock) ![]u8 {
    const alloc = cfg.alloc;
    if (!toolAllowed(tu.name)) {
        return alloc.dupe(u8, "tool not available to subagents");
    }
    const def = cfg.tools.findByName(tu.name) orelse {
        return alloc.dupe(u8, "unknown tool");
    };

    // The gate must be the CENTRAL pipeline (auth.checkToolPermission):
    // the registry's per-tool checkPermissions hook is registered by no
    // tool and defaults to .allow, so gating on it (v0.6.0) was a no-op —
    // Bash and every write tool ran unchecked. Default mode with EMPTY
    // rules gives exactly the headless semantics: read-only passes,
    // writes and protected paths fall through to ask — and ask is denied
    // here, because a headless worker must never block on a user.
    // M7 -p：perm_ctx 覆盖时走调用方上下文（oneshot 传用户 settings 的
    // 规则与模式）；ask 的降级语义不变——无人在场即拒绝。
    const fallback_ctx = registry.PermissionContext{
        .mode = .default,
        .allow_rules = &.{},
        .deny_rules = &.{},
        .ask_rules = &.{},
        .provider = cfg.provider,
        .allocator = alloc,
        .model_name = "",
    };
    const perm_ctx = cfg.perm_ctx orelse &fallback_ctx;
    const input = jsonFromToolUse(alloc, tu) catch return error.OutOfMemory;
    const decision = auth.checkToolPermission(def, input, perm_ctx);
    switch (decision) {
        .allow => {},
        .ask => |a| {
            const why = if (cfg.perm_ctx != null) "non-interactive" else "subagents are read-only";
            return std.fmt.allocPrint(alloc, "permission denied ({s}): {s}", .{ why, a.message });
        },
        .deny => |d| return std.fmt.allocPrint(alloc, "permission denied: {s}", .{d.message}),
    }
    // M6 Hooks：与 REPL 同一条纪律（权限 → Pre → 执行 → Post）——钩子对
    // 子代理/oneshot 的工具调用同样生效（全局配置，回合边界换装）。
    if (hooks_mod.preToolUse(alloc, cfg.io, tu.name, input)) |block_msg| {
        return block_msg;
    }
    const tr = try def.execute(alloc, input, cfg.io);
    hooks_mod.postToolUse(alloc, cfg.io, tu.name, input, tr.output);
    return alloc.dupe(u8, tr.output) catch error.OutOfMemory;
}

fn jsonFromToolUse(alloc: std.mem.Allocator, tu: llm.provider.ToolUseBlock) !std.json.Value {
    // The registry consumes std.json.Value objects; tool_use.input IS one.
    _ = alloc;
    return tu.input;
}

/// Cut `s` at a display/token budget, backing off to a UTF-8 boundary.
pub fn utf8TokenCut(s: []const u8, budget_tokens: u32) []const u8 {
    if (tokens_estimate(s) <= budget_tokens) return s;
    // estimateTokens ≈ ascii/4 + wide/2 — walk bytes, tracking the budget.
    var used: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[0..i];
        if (i + seq > s.len) return s[0..i];
        used += if (seq == 1) 1 else 2;
        if (used > budget_tokens) return s[0..i];
        i += seq;
    }
    return s;
}

fn tokens_estimate(s_: []const u8) u32 {
    var ascii: u32 = 0;
    var wide: u32 = 0;
    for (s_) |c| {
        if (c < 0x80) ascii += 1 else wide += 1;
    }
    return ascii / 4 + wide / 2;
}

test "utf8TokenCut respects budget and rune boundaries" {
    const short = "hello world";
    try std.testing.expectEqualStrings(short, utf8TokenCut(short, 500));
    var cjk_buf: [1200]u8 = undefined;
    var cw: usize = 0;
    while (cw + 6 <= cjk_buf.len) : (cw += 6) @memcpy(cjk_buf[cw..][0..6], "中文内容"[0..6]);
    const cjk = cjk_buf[0..cw];
    const cut = utf8TokenCut(cjk, 50);
    try std.testing.expect(cut.len < cjk.len);
    try std.testing.expect((cut.len % 3) == 0); // no mid-rune cut
}

test "toolAllowed whitelist (T6.2)" {
    try std.testing.expect(!toolAllowed("TaskCreate"));
    try std.testing.expect(!toolAllowed("TaskGet"));
    try std.testing.expect(!toolAllowed("BgTask"));
    // Registry CANONICAL name — the "AskUser" shorthand never matched
    // (exact eql) and let the real tool slip through (fixed 2026-11-10).
    try std.testing.expect(!toolAllowed("AskUserQuestion"));
    try std.testing.expect(toolAllowed("Grep"));
    try std.testing.expect(toolAllowed("FileRead"));
    try std.testing.expect(toolAllowed("Bash"));
    try std.testing.expect(!toolAllowed("agent")); // no recursive fan-out
}

test "toolVisible: dispatch whitelist narrows, never widens (M4)" {
    // null = 继承全量（仍走 deny 过滤）。
    try std.testing.expect(toolVisible("Grep", null));
    try std.testing.expect(!toolVisible("TaskCreate", null));
    try std.testing.expect(!toolVisible("AskUserQuestion", null));
    // 白名单命中才可见。
    const only = [_][]const u8{ "FileRead", "Grep" };
    try std.testing.expect(toolVisible("Grep", &only));
    try std.testing.expect(toolVisible("FileRead", &only));
    try std.testing.expect(!toolVisible("Bash", &only));
    // deny 永远优先——白名单列了也看不见。
    const bad = [_][]const u8{ "TaskCreate", "agent" };
    try std.testing.expect(!toolVisible("TaskCreate", &bad));
    try std.testing.expect(!toolVisible("agent", &bad));
}

test "subagent permission gate runs the CENTRAL pipeline (T6.2 wiring fix)" {
    // v0.6.0 regression this pins: gating on registry checkPermissions —
    // a hook no tool registers, defaulting to .allow — let write tools and
    // Bash through unchecked. The subagent ctx is Default mode + EMPTY
    // rules through auth.checkToolPermission: writes must land on ask
    // (= denied for a headless worker), reads on allow.
    const ctx = registry.PermissionContext{
        .mode = .default,
        .allow_rules = &.{},
        .deny_rules = &.{},
        .ask_rules = &.{},
        .provider = null,
        .allocator = null,
        .model_name = "",
    };
    const d_write = auth.checkToolPermission(&registry.file_write_tool, .null, &ctx);
    try std.testing.expect(d_write == .ask); // → "subagents are read-only"
    const d_read = auth.checkToolPermission(&registry.file_read_tool, .null, &ctx);
    try std.testing.expect(d_read == .allow);
    // Bash with no parsable command is NOT read-only (bashIsReadOnly
    // returns false on null input) → ask → denied for a subagent.
    const d_bash = auth.checkToolPermission(&registry.bash_tool, .null, &ctx);
    try std.testing.expect(d_bash != .allow);
}
