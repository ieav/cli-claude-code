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
const registry = @import("../tools/registry.zig");
const runtime_registry = @import("../tools/runtime_registry.zig");
const auth = @import("../tools/auth_mode.zig");

pub const MAX_TURNS: usize = 10;

/// Tools a subagent may never see: session-scoped task tracking and
/// interactive questions make no sense without the REPL around them.
const deny_tools = [_][]const u8{ "TaskCreate", "TaskList", "TaskUpdate", "AskUser", "agent" };

fn toolAllowed(name: []const u8) bool {
    for (deny_tools) |d| {
        if (std.mem.eql(u8, name, d)) return false;
    }
    return true;
}

/// Shared LLM gate (T6.4, probe-verified A2 pattern): pool workers run
/// tool calls TRULY in parallel, but LLM calls serialize through one
/// provider under a mutex — concurrent std.http use on one io asserts in
/// std.http.Client.deinit (probe A), serialized sharing is 5/5 stable
/// (probe A2). The lock also bounds a hung gateway to one victim.
pub const SubagentConfig = struct {
    task: []const u8,
    alloc: std.mem.Allocator,
    io: std.Io,
    provider: llm.Provider,
    tools: *runtime_registry.RuntimeRegistry,
    /// Hard turn cap; the caller may lower it further.
    max_turns: usize = MAX_TURNS,
};

pub const SubagentResult = struct {
    /// Final assistant text (allocator-owned by cfg.alloc).
    summary: []u8,
    turns_used: usize,
    tool_calls: usize,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.summary);
    }
};

const headless_system_prompt =
    \\You are a focused subagent. Complete the assigned task with the tools
    \\available, then reply with a concise result (what you found / did,
    \\key file paths, and anything the caller must know). You have no
    \\access to task tracking or user questions — work autonomously and
    \\report at the end.
;

/// Run one subagent to completion. Errors are folded into the summary so
/// the caller always gets printable text.
pub fn run(cfg: SubagentConfig) SubagentResult {
    var err_buf: ?[]u8 = null;
    const res = runInner(cfg) catch |e| blk: {
        err_buf = std.fmt.allocPrint(cfg.alloc, "subagent failed: {s}", .{@errorName(e)}) catch null;
        break :blk SubagentResult{ .summary = err_buf.?, .turns_used = 0, .tool_calls = 0 };
    };
    if (err_buf != null) return res; // summary already the error text
    return res;
}

fn runInner(cfg: SubagentConfig) !SubagentResult {
    const alloc = cfg.alloc;

    // Whitelisted tool specs (T6.2).
    var specs: std.ArrayList(llm.ToolSpec) = .empty;
    defer specs.deinit(alloc);
    for (cfg.tools.definitions()) |*def| {
        if (!toolAllowed(def.name)) continue;
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
    // system + task
    {
        const sb = try ba.alloc(llm.ContentBlock, 1);
        sb[0] = .{ .text = headless_system_prompt };
        try history.append(alloc, .{ .role = .system, .content = sb, .timestamp = 0 });
        const ub = try ba.alloc(llm.ContentBlock, 1);
        ub[0] = .{ .text = cfg.task };
        try history.append(alloc, .{ .role = .user, .content = ub, .timestamp = 0 });
    }

    var turn: usize = 0;
    var tool_calls: usize = 0;
    while (turn < cfg.max_turns) : (turn += 1) {
        const resp = try cfg.provider.complete(history.items, .{
            .max_tokens = 2048,
            .tools = specs.items,
        });
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
                if (t.len > 0 and final_text == null) final_text = try alloc.dupe(u8, t);
            },
            .tool_use => |tu| try tool_uses.append(alloc, tu), // DOM-backed: valid while the loop lives
            else => {},
        };

        if (tool_uses.items.len == 0) {
            const summary = final_text orelse try alloc.dupe(u8, "(no output)");
            return .{ .summary = summary, .turns_used = turn + 1, .tool_calls = tool_calls };
        }

        // Append the assistant turn (tool_use blocks), then results.
        const asst_blocks = try ba.alloc(llm.ContentBlock, tool_uses.items.len);
        for (tool_uses.items, 0..) |tu, i| asst_blocks[i] = .{ .tool_use = tu };
        try history.append(alloc, .{ .role = .assistant, .content = asst_blocks, .timestamp = 0 });

        for (tool_uses.items) |tu| {
            tool_calls += 1;
            const out = executeWhitelisted(cfg, tu) catch |e| blk: {
                break :blk std.fmt.allocPrint(alloc, "tool error: {s}", .{@errorName(e)}) catch "tool error";
            };
            // Execute results become the next user turn (single block per
            // call keeps the OpenAI tool-message mapping trivial).
            const rb = try ba.alloc(llm.ContentBlock, 1);
            rb[0] = .{ .tool_result = .{ .tool_use_id = ba.dupe(u8, tu.id) catch tu.id, .content = out } };
            try history.append(alloc, .{ .role = .user, .content = rb, .timestamp = 0 });
        }
    }
    return .{ .summary = try alloc.dupe(u8, "(turn limit reached)"), .turns_used = cfg.max_turns, .tool_calls = tool_calls };
}

/// Whitelist + Default-mode permission gate, then execute.
fn executeWhitelisted(cfg: SubagentConfig, tu: llm.provider.ToolUseBlock) ![]u8 {
    const alloc = cfg.alloc;
    if (!toolAllowed(tu.name)) {
        return alloc.dupe(u8, "tool not available to subagents");
    }
    const def = cfg.tools.findByName(tu.name) orelse {
        return alloc.dupe(u8, "unknown tool");
    };

    // Default-mode semantics with EMPTY rules: read-only passes, anything
    // that would ask a user is denied — a headless worker must never block.
    const perm_ctx = registry.PermissionContext{
        .mode = .default,
        .allow_rules = &.{},
        .deny_rules = &.{},
        .ask_rules = &.{},
        .provider = cfg.provider,
        .allocator = alloc,
        .model_name = "",
    };
    const input = jsonFromToolUse(alloc, tu) catch return error.OutOfMemory;
    const decision = def.checkPermissions(input, &perm_ctx);
    switch (decision) {
        .allow => {},
        else => {
            return std.fmt.allocPrint(alloc, "permission denied (subagents are read-only)", .{});
        },
    }
    const tr = try def.execute(alloc, input, cfg.io);
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
    try std.testing.expect(!toolAllowed("AskUser"));
    try std.testing.expect(toolAllowed("Grep"));
    try std.testing.expect(toolAllowed("FileRead"));
    try std.testing.expect(toolAllowed("Bash"));
    try std.testing.expect(!toolAllowed("agent")); // no recursive fan-out
}
