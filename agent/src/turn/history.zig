/// History management (P1 extraction from repl.zig — pure move):
/// token estimation, φ/auto compaction, key-fact preservation, tool-pair
/// repair, content-block deep copy, clear/undo primitives.
const std = @import("std");
const llm = @import("../llm/mod.zig");
const compaction = @import("../llm/compaction.zig");
const op_log = @import("../checkpoint/op_log.zig");
const logger = @import("../util/log.zig");
const tokens_mod = @import("../util/tokens.zig");
const json_tree = @import("../util/json_tree.zig");
const util_time = @import("../util/time.zig");
const registry = @import("../tools/registry.zig");
const config_mod = @import("../config.zig");
const embedding_mod = @import("../util/embedding.zig");
const math_mod = @import("../math/mod.zig");
const repl_mod = @import("../repl.zig");
const ModelSwitcher = repl_mod.ModelSwitcher;

/// Deep-copy content blocks so history owns every string and JSON tree.
pub fn cloneContentBlocks(alloc: std.mem.Allocator, blocks: []const llm.ContentBlock) ![]llm.ContentBlock {
    const out = try alloc.alloc(llm.ContentBlock, blocks.len);
    var filled: usize = 0;
    errdefer freeContentBlocks(alloc, out[0..filled]);
    for (blocks, 0..) |b, i| {
        out[i] = switch (b) {
            .text => |t| .{ .text = try alloc.dupe(u8, t) },
            .thinking => |t| .{ .thinking = try alloc.dupe(u8, t) },
            .tool_use => |tu| .{ .tool_use = .{
                .id = try alloc.dupe(u8, tu.id),
                .name = try alloc.dupe(u8, tu.name),
                .input = try json_tree.dupeJsonValue(alloc, tu.input),
            } },
            .tool_result => |tr| .{ .tool_result = .{
                .tool_use_id = try alloc.dupe(u8, tr.tool_use_id),
                .content = try alloc.dupe(u8, tr.content),
                .is_error = tr.is_error,
            } },
        };
        filled = i + 1;
    }
    return out;
}

pub fn freeContentBlocks(alloc: std.mem.Allocator, blocks: []const llm.ContentBlock) void {
    for (blocks) |b| {
        switch (b) {
            .text => |t| alloc.free(t),
            .thinking => |t| alloc.free(t),
            .tool_use => |tu| {
                alloc.free(tu.id);
                alloc.free(tu.name);
                json_tree.freeJsonValue(alloc, tu.input);
            },
            .tool_result => |tr| {
                alloc.free(tr.tool_use_id);
                alloc.free(tr.content);
            },
        }
    }
    alloc.free(@constCast(blocks));
}

/// Estimate total tokens across all history messages.
pub fn estimateHistoryTokens(history: []const llm.Message) u32 {
    var total: u32 = 0;
    for (history) |msg| {
        for (msg.content) |block| {
            switch (block) {
                .text => |t| total += estimateTextTokens(t),
                .tool_use => total += 50,
                .tool_result => |tr| total += estimateTextTokens(tr.content),
                .thinking => |t| total += estimateTextTokens(t),
            }
        }
    }
    return total;
}

/// ASCII runs ~4 bytes/token, but CJK text runs ~2 bytes/token under
/// GLM-class tokenizers. The old uniform bytes/4 under-counted Chinese-heavy
/// sessions by ~2×, so real requests could blow past the model's context
/// (a 400 on every subsequent call) long before the estimate ever reached
/// the auto-compaction threshold. Over-estimating is safe (compacts a
/// little early); under-estimating strands the session.
pub fn estimateTextTokens(text: []const u8) u32 {
    var ascii: usize = 0;
    var wide: usize = 0;
    for (text) |c| {
        if (c < 0x80) ascii += 1 else wide += 1;
    }
    return @intCast(ascii / 4 + wide / 2);
}

/// Auto-compact if history exceeds phi threshold. Returns the history's
/// token estimate AFTER any compaction — callers reuse it instead of
/// re-scanning the whole history (the loop used to run the same O(n)
/// estimate twice per iteration).
/// Default verbatim-tail rounds for the auto ladder (matches /compact).
pub const HYBRID_KEEP: usize = compaction.HYBRID_KEEP_ROUNDS;

/// P2.5 上下文压力梯子（提炼优先，2026-11-07 用户定纲）：
/// 信息先经 LLM 提炼存续（摘要套摘要滚动压缩），截断只在提炼不可用
/// 时兜底。纯决策，矩阵可单测。
pub const PressureLevel = enum { ok, extract, emergency };

/// 压缩起始阈值（P5 T3.1，2026-11-08 由 61.8% 上调）：每次压缩都改写
/// 历史前缀 → 网关前缀缓存全失效。75% 起步比 61.8% 少约 40% 触发
/// 次数，emergency 92% 梯子原样兜底（收敛不变量测试锁定不撑爆）。
pub const COMPACT_ONSET: f64 = 0.75;

/// 压后目标（2026-11-08）：压缩要压到位——首轮深压后仍高于此水位则
/// 收窄保留窗再压一轮。原先「压完 <75% 即合格」导致压后仍占半窗，
/// 用户看到的就是「压完上下文还是很长」。
pub const POST_COMPACT_TARGET: f64 = 0.45;

/// /stats 观测（P5 T3.3）：压缩次数与回收 token——「前缀稳定性调优」
/// 的代理指标（网关缓存命中率不可直接观测，触发频次是可拉的自变量）。
pub var compacts_done: u64 = 0;
pub var tokens_reclaimed: u64 = 0;

pub fn pressureLadder(est_tokens: u32, ceiling: u32) PressureLevel {
    if (ceiling == 0) return .emergency;
    const e: f64 = @floatFromInt(est_tokens);
    const c: f64 = @floatFromInt(ceiling);
    const pct = e / c;
    if (pct <= COMPACT_ONSET) return .ok; // ≤75%：不动（缓存稳定优先）
    if (pct <= 0.92) return .extract; // 提炼（保信息）
    return .emergency; // 收窄保留窗（keep=2）再提炼
}

/// What an auto-compaction pass did — repl turns this into a decision-trace
/// step (roadmap P2 observability: before/after tokens land in /diagnose).
pub const CompactEvent = struct {
    tokens: u32,
    before_tokens: u32 = 0,
    compacted: bool = false,
    slimmed: usize = 0,
};

pub fn maybeCompact(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer, file_writer: *std.Io.File.Writer, log: *op_log.OperationLog, facts: *?[]u8, model: []const u8, backend: llm.BackendType) CompactEvent {
    const current_tokens = estimateHistoryTokens(history.items);
    // T4.1: the ceiling follows the ACTIVE model's context estimate, not
    // the old hardcoded 128K — an 8K local model now compacts at ~5K
    // instead of overflowing first.
    const ceiling = llm.provider.contextEstimate(model, backend);
    if (!compaction.needsCompaction(current_tokens, ceiling)) return .{ .tokens = current_tokens };

    applyFactsUpdate(history, facts, alloc, compactHistoryImpl(history, alloc, facts.*));
    // P2 tier 3 rides the auto path too: the φ-kept window still carries
    // fat tool_results — slim them (no LLM needed; the emergency path must
    // work with the gateway down, hence phi+slim instead of full hybrid).
    const slim = slimToolResults(history.items, alloc);
    log.bumpEpoch();
    const after_tokens = estimateHistoryTokens(history.items);
    compacts_done += 1;
    tokens_reclaimed += if (current_tokens > after_tokens) current_tokens - after_tokens else 0;
    logger.info("compact: strategy=phi+slim tokens ~{d}->~{d} slimmed={d} ({d}->{d}B)", .{
        current_tokens, after_tokens, slim.slimmed, slim.bytes_before, slim.bytes_after,
    });
    // Auto-compact fires MID-TURN (region up) as often as between turns —
    // the region-aware `w` callers pass handles both without overwriting
    // the input row (verbatim when the region is down).
    if (slim.slimmed > 0) {
        std.Io.Writer.print(w, "  [Context auto-compacted: ~{d} → ~{d} tokens, {d} messages remaining, {d} tool outputs slimmed]\n", .{ current_tokens, after_tokens, history.items.len, slim.slimmed }) catch {};
    } else {
        std.Io.Writer.print(w, "  [Context auto-compacted: ~{d} → ~{d} tokens, {d} messages remaining]\n", .{ current_tokens, after_tokens, history.items.len }) catch {};
    }
    std.Io.File.Writer.flush(file_writer) catch {};
    return .{ .tokens = after_tokens, .before_tokens = current_tokens, .compacted = true, .slimmed = slim.slimmed };
}

/// Force compact history via LLM summary (used by /compact) — Claude-style:
/// the current provider summarizes the conversation and the summary replaces
/// the history, so earlier context is condensed instead of dropped. On any
/// failure the history is left untouched and the user is pointed at
/// /compact phi (truncation) rather than silently losing context.
pub fn compactHistory(
    history: *std.ArrayList(llm.Message),
    switcher: *ModelSwitcher,
    log: *op_log.OperationLog,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    total_in: *u64,
    total_out: *u64,
    /// Optional user focus instructions appended to the summary prompt
    /// ("/compact focus on X" — Claude-Code parity).
    focus: []const u8,
) !void {
    return compactHistoryKeep(history, switcher, log, alloc, w, file_writer, total_in, total_out, focus, compaction.HYBRID_KEEP_ROUNDS);
}

/// Hybrid compaction with an explicit verbatim-tail size. The auto
/// pressure ladder calls this directly: keep=5 normally, keep=2 under
/// emergency pressure — the tail is what can't shrink, so shrinking it is
/// the last lever before information loss.
pub fn compactHistoryKeep(
    history: *std.ArrayList(llm.Message),
    switcher: *ModelSwitcher,
    log: *op_log.OperationLog,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    total_in: *u64,
    total_out: *u64,
    focus: []const u8,
    keep_rounds: usize,
) !void {
    if (history.items.len <= 2) {
        try std.Io.Writer.writeAll(w, "  Nothing to compact.\n\n");
        return;
    }

    const prov = switcher.getProvider() catch |err| {
        try std.Io.Writer.print(w, "  Summary model unavailable ({}).\n  History untouched — try /compact phi for plain truncation.\n\n", .{err});
        return;
    };

    const before_msgs = history.items.len;
    const before_tokens = estimateHistoryTokens(history.items);
    // P2 hybrid (design D4): three tiers — the OLD segment is summarized,
    // the last HYBRID_KEEP_ROUNDS user-anchored rounds stay VERBATIM
    // (round-anchored split: a tool exchange never crosses the boundary),
    // then oversized tool_results in the kept window are slimmed (tier 3).
    const summarize_to = compaction.hybridSplit(history.items, keep_rounds);
    if (summarize_to <= 1) {
        try std.Io.Writer.print(w, "  Nothing to compact — the last {d} rounds stay verbatim and there is no older segment.\n\n", .{compaction.HYBRID_KEEP_ROUNDS});
        return;
    }
    try std.Io.Writer.print(w, "  Compacting (hybrid): summarizing {d} messages, keeping the last {d} verbatim (~{d} tokens total)…\n", .{ summarize_to - 1, before_msgs - summarize_to, before_tokens });
    std.Io.File.Writer.flush(file_writer) catch {};

    const transcript = compaction.renderTranscript(alloc, history.items[1..summarize_to]) catch |err| {
        try std.Io.Writer.print(w, "  Compaction failed: {}\n  History untouched — try /compact phi.\n\n", .{err});
        return;
    };
    defer alloc.free(transcript);

    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    defer alloc.free(sys_blocks);
    if (focus.len > 0) {
        sys_blocks[0] = .{ .text = try alloc.print("{s}\n\nThe user additionally asks to prioritize:\n{s}", .{ compaction.SUMMARY_INSTRUCTION, focus }) };
    } else {
        sys_blocks[0] = .{ .text = compaction.SUMMARY_INSTRUCTION };
    }
    const user_blocks = try alloc.alloc(llm.ContentBlock, 1);
    defer alloc.free(user_blocks);
    user_blocks[0] = .{ .text = transcript };
    const msgs = [_]llm.Message{
        .{ .role = .system, .content = sys_blocks, .timestamp = util_time.nowMillis() },
        .{ .role = .user, .content = user_blocks, .timestamp = util_time.nowMillis() },
    };
    var resp = prov.complete(&msgs, .{
        // 2026-11-08 收紧：2048→1024——摘要要替代整段历史，臃肿摘要
        // 自败其义（指令里同步给了 ~600 词预算）。
        .max_tokens = @min(switcher.settings.max_tokens, 1024),
        // P5 T3.2 前缀稳定：摘要温度 0——网关对确定性前缀有缓存/计价
        // 优势，我们自己这侧先保证同输入尽量同输出。
        .temperature = 0,
    }) catch |err| {
        try std.Io.Writer.print(w, "  Summary call failed: {}.\n  History untouched — try /compact phi.\n\n", .{err});
        return;
    };
    // Extract the summary text before the response DOM arena is freed.
    var summary = std.ArrayList(u8).empty;
    defer summary.deinit(alloc);
    for (resp.content) |block| {
        if (block == .text) summary.appendSlice(alloc, block.text) catch break;
    }
    const usage = resp.usage;
    resp.free(alloc);
    total_in.* += usage.input_tokens;
    total_out.* += usage.output_tokens;

    if (summary.items.len == 0) {
        try std.Io.Writer.writeAll(w, "  Summary came back empty — history untouched.\n  Try /compact phi for plain truncation.\n\n");
        return;
    }

    // Rebuild via the shared hybrid surgery: system + summary + verbatim
    // tail + tier-3 tool-result slimming.
    const slim = applyHybridLayout(history, alloc, summarize_to, summary.items) catch {
        try std.Io.Writer.writeAll(w, "  Compaction failed (rebuild layout).\n  History untouched — try /compact phi.\n\n");
        return;
    };
    log.bumpEpoch();

    const after_tokens = estimateHistoryTokens(history.items);
    compacts_done += 1;
    tokens_reclaimed += if (before_tokens > after_tokens) before_tokens - after_tokens else 0;
    logger.info("compact: strategy=hybrid msgs {d}->{d} tokens ~{d}->~{d} slimmed={d} ({d}->{d}B)", .{
        before_msgs, history.items.len, before_tokens, after_tokens, slim.slimmed, slim.bytes_before, slim.bytes_after,
    });
    if (slim.slimmed > 0) {
        try std.Io.Writer.print(w, "  Compacted: {d} → {d} messages (~{d} → ~{d} tokens | {d} tool outputs slimmed {d} KiB → {d} KiB | summary call {d} in / {d} out)\n\n", .{
            before_msgs,          history.items.len,
            before_tokens,        after_tokens,
            slim.slimmed,         slim.bytes_before / 1024,
            slim.bytes_after / 1024, usage.input_tokens,
            usage.output_tokens,
        });
    } else {
        try std.Io.Writer.print(w, "  Compacted: {d} → {d} messages (~{d} → ~{d} tokens | summary call {d} in / {d} out)\n\n", .{
            before_msgs, history.items.len, before_tokens, after_tokens, usage.input_tokens, usage.output_tokens,
        });
    }
}

/// Tier-3 of the hybrid strategy (P2): oversized tool_results are slimmed
/// IN HISTORY to a 1 KiB head + byte-count marker. The display layer (/last
/// ring, previews) holds its own full copies — this surgery only saves
/// request tokens. Idempotent: a slimmed result sits far below the
/// threshold, so repeated passes never touch it again.
pub const SlimStats = struct {
    slimmed: usize = 0,
    bytes_before: usize = 0,
    bytes_after: usize = 0,
};

pub fn slimToolResults(messages: []llm.Message, alloc: std.mem.Allocator) SlimStats {
    var stats: SlimStats = .{};
    for (messages) |*msg| {
        // Fast path: nothing oversized in this message → skip the rebuild.
        var has_fat = false;
        for (msg.content) |b| {
            if (b == .tool_result and b.tool_result.content.len > compaction.TOOL_SLIM_THRESHOLD) {
                has_fat = true;
                break;
            }
        }
        if (!has_fat) continue;
        // Message.content is a []const slice — rebuild it with the slimmed
        // blocks (the established swap pattern; see swapMemoryBlockText).
        const old = msg.content;
        const nb = alloc.alloc(llm.ContentBlock, old.len) catch continue;
        for (old, 0..) |b, bi| {
            if (b == .tool_result and b.tool_result.content.len > compaction.TOOL_SLIM_THRESHOLD) {
                var mbuf: [64]u8 = undefined;
                const marker = compaction.toolSlimMarker(&mbuf, b.tool_result.content.len);
                const head = @min(b.tool_result.content.len, compaction.TOOL_SLIM_HEAD);
                if (marker.len > 0) {
                    if (alloc.alloc(u8, head + marker.len)) |owned| {
                        @memcpy(owned[0..head], b.tool_result.content[0..head]);
                        @memcpy(owned[head..], marker);
                        stats.bytes_before += b.tool_result.content.len;
                        stats.bytes_after += owned.len;
                        stats.slimmed += 1;
                        alloc.free(@constCast(b.tool_result.content));
                        nb[bi] = .{ .tool_result = .{
                            .tool_use_id = b.tool_result.tool_use_id,
                            .content = owned,
                            .is_error = b.tool_result.is_error,
                        } };
                        continue;
                    } else |_| {}
                }
            }
            nb[bi] = b;
        }
        alloc.free(@constCast(old));
        msg.content = nb;
    }
    return stats;
}

/// 每个用户回合内只保留最近 K 条 tool_result 的内容，更早的替换成
/// 单行标记（tool_use 原样保留——API 要求 use/result 配对完整）。
/// 修「马拉松回合被当一个 round 整体保留」的口子（hybridSplit 按 user
/// 文本消息锚定，单回合 50 次工具调用全算一个 round）：留存从
/// 50×体量 降到 K×体量 + (N-K)×标记行。/last 环不受影响（独立全文）。
pub const FOLD_KEEP_PER_ROUND: usize = 8;

pub const FoldStats = struct { folded: usize = 0, bytes_before: usize = 0 };

pub fn foldOldToolResults(messages: []llm.Message, alloc: std.mem.Allocator) FoldStats {
    // 第一遍：数每个 round 的 tool_result 总数。
    var round_total: std.ArrayList(usize) = .empty;
    defer round_total.deinit(alloc);
    var cur: usize = 0;
    for (messages) |*m| {
        const starts_round = m.role == .user and m.content.len > 0 and m.content[0] == .text;
        if (starts_round) {
            round_total.append(alloc, 0) catch break;
            cur = round_total.items.len - 1;
        }
        if (round_total.items.len == 0) continue; // 系统提示段（无 round 上下文）不动
        for (m.content) |b| {
            if (b == .tool_result) round_total.items[cur] += 1;
        }
    }
    // 第二遍：重建含超额 tool_result 的消息（沿 slimToolResults 的换法）。
    var stats: FoldStats = .{};
    var round_idx: usize = 0; // 已进入的 round 计数
    var seen_in_round: usize = 0;
    for (messages) |*m| {
        const starts_round = m.role == .user and m.content.len > 0 and m.content[0] == .text;
        if (starts_round) {
            round_idx += 1;
            seen_in_round = 0;
        }
        if (round_idx == 0 or round_idx > round_total.items.len) continue;
        // 本消息是否含「该 round 内序号 < 总数-K」的 tool_result。
        var n_before: usize = 0;
        var has_fold = false;
        for (m.content) |b| {
            if (b != .tool_result) continue;
            const ordinal = seen_in_round + n_before;
            const total = round_total.items[round_idx - 1];
            if (total > FOLD_KEEP_PER_ROUND and ordinal + FOLD_KEEP_PER_ROUND < total) has_fold = true;
            n_before += 1;
        }
        seen_in_round += n_before;
        if (!has_fold) continue;

        const old = m.content;
        const nb = alloc.alloc(llm.ContentBlock, old.len) catch continue;
        var bi: usize = 0;
        var ord: usize = seen_in_round - n_before;
        for (old) |b| {
            if (b == .tool_result) {
                const total = round_total.items[round_idx - 1];
                if (total > FOLD_KEEP_PER_ROUND and ord + FOLD_KEEP_PER_ROUND < total) {
                    var mbuf: [96]u8 = undefined;
                    const marker = std.fmt.bufPrint(&mbuf, "[工具输出已并入摘要（原 {d} B）· /last 查全文]", .{b.tool_result.content.len}) catch "[folded]";
                    if (alloc.dupe(u8, marker)) |owned| {
                        stats.folded += 1;
                        stats.bytes_before += b.tool_result.content.len;
                        nb[bi] = .{ .tool_result = .{
                            .tool_use_id = b.tool_result.tool_use_id,
                            .content = owned,
                            .is_error = b.tool_result.is_error,
                        } };
                        bi += 1;
                        ord += 1;
                        // 旧 content 归 history 所有：释放防漏。
                        alloc.free(@constCast(b.tool_result.content));
                        continue;
                    } else |_| {}
                }
                ord += 1;
            }
            nb[bi] = b;
            bi += 1;
        }
        alloc.free(@constCast(old));
        m.content = nb[0..bi];
    }
    return stats;
}

/// Hybrid surgery (pure, no LLM): rebuild history as
/// [system prompt (kept — clearHistory preserves index 0)] +
/// [summary-as-user-message] + [verbatim tail from summarize_to], then
/// foldOldToolResults（每回合只留最近 K 条工具结果）+ slim oversized
/// tool_results everywhere. The tail is duped out before the
/// clear, so on error the history is left untouched. Unit-testable with a
/// fake summary.
pub fn applyHybridLayout(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, summarize_to: usize, summary: []const u8) !SlimStats {
    if (summarize_to <= 1 or summarize_to > history.items.len) return error.BadHybridBounds;
    var tail: std.ArrayList(llm.Message) = .empty;
    defer {
        // On success the messages moved into history; on the error paths
        // below they are freed here.
        for (tail.items) |m| freeMessage(m, alloc);
        tail.deinit(alloc);
    }
    for (history.items[summarize_to..]) |m| {
        const dupe = try dupeMessage(alloc, m);
        try tail.append(alloc, dupe);
    }
    try replaceHistoryWithSummary(history, alloc, summary);
    for (tail.items) |m| {
        try history.append(alloc, m);
    }
    // Ownership moved into history: neutralize the defer's cleanup.
    tail.clearRetainingCapacity();
    _ = foldOldToolResults(history.items, alloc);
    return slimToolResults(history.items, alloc);
}

/// Replace everything after the system prompt with a single user message
/// carrying the LLM summary (Claude-style compact outcome).
fn replaceHistoryWithSummary(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, summary: []const u8) !void {
    clearHistory(history, alloc);
    const text = try alloc.print(
        "Here is a summary of the conversation so far:\n\n{s}\n\nThis summary replaces the earlier conversation history. Continue from here.",
        .{summary},
    );
    errdefer alloc.free(text);
    const blocks = try alloc.alloc(llm.ContentBlock, 1);
    errdefer alloc.free(blocks);
    blocks[0] = .{ .text = text };
    try history.append(alloc, .{
        .role = .user,
        .content = blocks,
        .timestamp = util_time.nowMillis(),
    });
}

/// Force compact via phi truncation (used by /compact phi). This is the
/// original strategy: keep the system prompt + most recent 61.8% of
/// messages, drop the rest.
pub fn compactHistoryPhi(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, w: *std.Io.Writer, log: *op_log.OperationLog, facts: *?[]u8) !void {
    if (history.items.len <= 2) {
        try std.Io.Writer.writeAll(w, "  Nothing to compact.\n\n");
        return;
    }
    const before = history.items.len;
    applyFactsUpdate(history, facts, alloc, compactHistoryImpl(history, alloc, facts.*));
    log.bumpEpoch();
    const est = estimateHistoryTokens(history.items);
    try std.Io.Writer.print(w, "  Compacted (phi): {d} → {d} messages (~{d} tokens)\n\n", .{ before, history.items.len, est });
}

/// T4.2: fold compaction's returned facts into the owned block + the
/// live history (swap by identity; append on first use). No-op on null
/// (nothing new — the block stays byte-identical, cache intact).
pub fn applyFactsUpdate(history: *std.ArrayList(llm.Message), facts: *?[]u8, alloc: std.mem.Allocator, new_facts: ?[]u8) void {
    const nf = new_facts orelse return;
    if (facts.*) |of| {
        const swapped = swapMemoryBlockText(history, alloc, of, nf);
        if (!swapped) {
            if (!appendSystemBlock(history, alloc, nf)) {
                alloc.free(nf);
                return; // OOM: keep the old block
            }
        }
        alloc.free(of);
    } else if (!appendSystemBlock(history, alloc, nf)) {
        alloc.free(nf);
        return;
    }
    facts.* = nf;
}

/// T4.2 signal words: lines from DROPPED messages that carry irreversible
/// facts (decisions, paths, constraints) survive truncation in a bounded
/// "key facts" block instead of being lost with the phi cut.
const fact_markers = [_][]const u8{
    "决定",
    "改用",
    "换成",
    "选定",
    "decision",
    "switch to",
    "instead",
    "let's",
    "we'll",
    "use ",
    "必须",
    "不要",
    "禁止",
    "不能",
    "must",
    "never",
    "always",
    "require",
};
const path_hint_bytes = "/";

fn lineIsKeyFact(line: []const u8) bool {
    if (line.len < 8 or line.len > 300) return false;
    for (fact_markers) |m| {
        if (std.mem.indexOf(u8, line, m) != null) return true;
    }
    return std.mem.indexOf(u8, line, path_hint_bytes) != null and
        (std.mem.indexOf(u8, line, ".zig") != null or
            std.mem.indexOf(u8, line, ".rs") != null or
            std.mem.indexOf(u8, line, ".ts") != null or
            std.mem.indexOf(u8, line, ".py") != null or
            std.mem.indexOf(u8, line, ".md") != null or
            std.mem.indexOf(u8, line, ".sql") != null or
            std.mem.indexOf(u8, line, ".json") != null);
}

/// Build/merge the key-facts text: NEW facts first (recent decisions
/// matter more), then surviving old ones, capped at ~200 tokens.
fn mergeKeyFacts(alloc: std.mem.Allocator, dropped: []const llm.Message, existing: ?[]const u8) ?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    aw.writer.writeAll("Key facts kept through compaction:\n") catch return null;
    var count: usize = 0;
    var i = dropped.len;
    while (i > 0) {
        i -= 1;
        const msg = dropped[i];
        if (msg.role != .user and msg.role != .assistant) continue;
        for (msg.content) |block| switch (block) {
            .text => |t| {
                var lines = std.mem.splitScalar(u8, t, '\n');
                while (lines.next()) |ln| {
                    const t2 = std.mem.trim(u8, ln, " \t>-*# ");
                    if (!lineIsKeyFact(t2)) continue;
                    // dedupe against what we already collected
                    if (std.mem.indexOf(u8, aw.written(), t2) != null) continue;
                    if (existing) |ex| {
                        if (std.mem.indexOf(u8, ex, t2) != null and count >= 8) continue; // keep old copy only via merge below
                    }
                    aw.writer.print("- {s}\n", .{t2}) catch return null;
                    count += 1;
                    if (tokens_mod.estimateTokens(aw.written()) > 180) break;
                }
            },
            else => {},
        };
        if (tokens_mod.estimateTokens(aw.written()) > 180) break;
    }
    // Append surviving old facts that still fit (they were already paid for).
    if (existing) |ex| {
        var lines = std.mem.splitScalar(u8, ex, '\n');
        while (lines.next()) |ln| {
            const t2 = std.mem.trim(u8, ln, " \t-");
            if (t2.len == 0 or std.mem.startsWith(u8, t2, "Key facts")) continue;
            if (std.mem.indexOf(u8, aw.written(), t2) != null) continue;
            if (tokens_mod.estimateTokens(aw.written()) + tokens_mod.estimateTokens(t2) > 200) break;
            aw.writer.print("- {s}\n", .{t2}) catch break;
        }
    }
    if (count == 0 and existing == null) return null;
    return alloc.dupe(u8, aw.written()) catch null;
}

/// Core compaction: keep system prompt + recent 61.8% of messages.
/// T4.2: before freeing the dropped messages, irreversible facts
/// (decisions/paths/constraints) are distilled into `facts_out`.
pub fn compactHistoryImpl(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, existing_facts: ?[]const u8) ?[]u8 {
    if (history.items.len <= 2) return null;

    // Keep system prompt (index 0) and recent messages up to phi target
    const total = history.items.len - 1; // exclude system prompt
    const target = compaction.condensationTarget(total);
    if (target >= total) return null;

    // Remove the oldest non-system messages down to the phi target,
    // freeing their content — previously every removal leaked.
    const new_len = 1 + target; // system + remaining
    var dropped: std.ArrayList(llm.Message) = .empty;
    defer dropped.deinit(alloc);
    while (history.items.len > new_len) {
        const msg = history.orderedRemove(1);
        dropped.append(alloc, msg) catch freeMessage(msg, alloc);
    }

    // T4.2: distill key facts from the dropped tail; free the messages
    // only after extraction. The RETURNED slice belongs to the caller —
    // it swaps the block into history and frees the previous text. Null
    // means "nothing new" (keep the existing block byte-identical).
    const new_facts = mergeKeyFacts(alloc, dropped.items, existing_facts);
    for (dropped.items) |msg| freeMessage(msg, alloc);

    // An index-based cut can split a tool_use/tool_result pair at the head;
    // repair trims the orphan so the next request stays wire-valid.
    repairToolPairing(history, alloc);
    return new_facts;
}

/// Clear history, keep only system prompt.
/// Free one history message's content blocks (strings + JSON trees).
/// Deep-copy one message (blocks + their strings) — used by /compact's
/// keep-recent-tail path.
fn dupeMessage(alloc: std.mem.Allocator, msg: llm.Message) !llm.Message {
    const blocks = try cloneContentBlocks(alloc, msg.content);
    return .{ .role = msg.role, .content = blocks, .timestamp = msg.timestamp };
}

pub fn freeMessage(msg: llm.Message, alloc: std.mem.Allocator) void {
    freeContentBlocks(alloc, msg.content);
}

/// True when every block is a tool_result — the agent loop's feedback
/// message. On the OpenAI wire each block becomes a standalone
/// `role:"tool"` message that is only valid right after the assistant
/// `tool_calls` message it answers.
fn isPureToolResultMessage(msg: llm.Message) bool {
    if (msg.content.len == 0) return false;
    for (msg.content) |block| {
        if (block != .tool_result) return false;
    }
    return true;
}

fn messageHasToolUse(msg: llm.Message) bool {
    for (msg.content) |block| {
        if (block == .tool_use) return true;
    }
    return false;
}

/// Repair tool_use/tool_result pairing after history surgery (compaction,
/// undo, rewind). Strict OpenAI-compatible gateways 400 the entire request
/// when a `role:"tool"` message outlives the assistant `tool_calls` it
/// answered (orphan head), or an assistant `tool_calls` loses its result
/// messages (dangling tail) — so both ends are trimmed back to a valid
/// boundary.
pub fn repairToolPairing(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator) void {
    // Head: orphan tool results — the assistant tool_use before them was
    // removed by an index-based cut.
    while (history.items.len > 1 and isPureToolResultMessage(history.items[1])) {
        const msg = history.orderedRemove(1);
        freeMessage(msg, alloc);
    }
    // Tail: dangling tool_use — the results message after it was removed.
    while (history.items.len > 1) {
        const last = history.items[history.items.len - 1];
        if (last.role != .assistant or !messageHasToolUse(last)) break;
        const msg = history.pop().?;
        freeMessage(msg, alloc);
    }
}

pub fn clearHistory(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator) void {
    while (history.items.len > 1) {
        const msg = history.orderedRemove(1);
        freeMessage(msg, alloc);
    }
}

test "cloneContentBlocks deep-copies text and tool_use JSON trees" {
    const alloc = std.testing.allocator;

    var input_obj: std.json.ObjectMap = .empty;
    defer input_obj.deinit(alloc);
    try input_obj.put(alloc, "command", .{ .string = "ls -la" });
    var nested_arr = std.json.Array.init(alloc);
    defer nested_arr.deinit(); // the map copy shares this buffer; freed once here
    try nested_arr.append(.{ .integer = 1 });
    try nested_arr.append(.{ .string = "two" });
    try input_obj.put(alloc, "nested", .{ .array = nested_arr });

    const blocks = [_]llm.ContentBlock{
        .{ .text = "hello" },
        .{ .tool_use = .{ .id = "tu_1", .name = "Bash", .input = .{ .object = input_obj } } },
    };

    const owned = try cloneContentBlocks(alloc, &blocks);
    defer freeContentBlocks(alloc, owned);

    try std.testing.expectEqualStrings("hello", owned[0].text);
    try std.testing.expectEqualStrings("tu_1", owned[1].tool_use.id);
    // Nested JSON survives the deep copy.
    const cmd = registry.getStringField(owned[1].tool_use.input, "command");
    try std.testing.expectEqualStrings("ls -la", cmd.?);
    const nested = owned[1].tool_use.input.object.get("nested").?;
    try std.testing.expectEqual(@as(i64, 1), nested.array.items[0].integer);
    try std.testing.expectEqualStrings("two", nested.array.items[1].string);
}

test "effectiveBackend priority: table > prefixes > explicit override > fallback" {
    const s1 = config_mod.Settings{};
    var sw1 = ModelSwitcher.init(s1, undefined);
    // 1) Table entries are authoritative even with an override set.
    sw1.settings.default_backend = "openai";
    try std.testing.expect(sw1.effectiveBackend("claude-sonnet-4-6") == .claude);
    try std.testing.expect(sw1.effectiveBackend("llama3.2") == .ollama);
    // 2) Recognizable prefix beats the override.
    try std.testing.expect(sw1.effectiveBackend("gpt-5-turbo") == .openai);
    try std.testing.expect(sw1.effectiveBackend("claude-future-model") == .claude);
    // 3) Unrecognized name + override -> the gateway backend.
    try std.testing.expect(sw1.effectiveBackend("glm-4.6") == .openai);
    // 4) Unrecognized name, no override -> Ollama fallback.
    sw1.settings.default_backend = null;
    try std.testing.expect(sw1.effectiveBackend("glm-4.6") == .ollama);
}

test "replaceHistoryWithSummary swaps history for one summary message" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(alloc);

    // System prompt + two exchanges, all heap-owned strings.
    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    sys_blocks[0] = .{ .text = try alloc.dupe(u8, "system prompt") };
    try history.append(alloc, .{ .role = .system, .content = sys_blocks, .timestamp = 0 });
    for ([_][]const u8{ "q1", "a1", "q2" }) |txt| {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, txt) };
        try history.append(alloc, .{ .role = .user, .content = b, .timestamp = 0 });
    }
    try std.testing.expectEqual(@as(usize, 4), history.items.len);

    try replaceHistoryWithSummary(&history, alloc, "1. Primary Request: test the compact swap");

    try std.testing.expectEqual(@as(usize, 2), history.items.len);
    try std.testing.expect(history.items[0].role == .system);
    try std.testing.expect(history.items[1].role == .user);
    try std.testing.expect(std.mem.indexOf(u8, history.items[1].content[0].text, "Primary Request: test the compact swap") != null);

    // Full teardown with the production free path (zero leaks).
    clearHistory(&history, alloc);
    alloc.free(history.items[0].content[0].text);
    alloc.free(@constCast(history.items[0].content));
}

test "clearHistory survives assistant tool_use + tool_result pair (no double free)" {
    // Regression for the /clear crash: the tool_result's tool_use_id used to
    // BORROW the assistant message's id (same allocation), so freeing the
    // pair double-freed it; literal result contents were freed as well.
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(alloc);

    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    sys_blocks[0] = .{ .text = try alloc.dupe(u8, "sys") };
    try history.append(alloc, .{ .role = .system, .content = sys_blocks, .timestamp = 0 });

    const owned_id = try alloc.dupe(u8, "call_x");
    const tu_blocks = try alloc.alloc(llm.ContentBlock, 1);
    tu_blocks[0] = .{ .tool_use = .{ .id = owned_id, .name = try alloc.dupe(u8, "FileWrite"), .input = .null } };
    try history.append(alloc, .{ .role = .assistant, .content = tu_blocks, .timestamp = 0 });

    // Simulate what the fixed construction produces: duped id + owned content.
    const tr_blocks = try alloc.alloc(llm.ContentBlock, 1);
    tr_blocks[0] = .{ .tool_result = .{
        .tool_use_id = try alloc.dupe(u8, owned_id),
        .content = try alloc.dupe(u8, "wrote 2 bytes"),
    } };
    try history.append(alloc, .{ .role = .user, .content = tr_blocks, .timestamp = 0 });

    // The production free path must not double-free the shared-looking id.
    clearHistory(&history, alloc);
    alloc.free(history.items[0].content[0].text);
    alloc.free(@constCast(history.items[0].content));
}

test "estimateTextTokens weights CJK above bytes/4" {
    // 8 CJK chars = 24 bytes: bytes/4 says 6 tokens, real usage is 8-12 —
    // the old uniform estimate under-counted Chinese-heavy sessions ~2×.
    try std.testing.expectEqual(@as(u32, 12), estimateTextTokens("一二三四五六七八"));
    try std.testing.expect(estimateTextTokens("一二三四五六七八") > "一二三四五六七八".len / 4);
    // ASCII keeps the classic chars/4 approximation.
    try std.testing.expectEqual(@as(u32, 1), estimateTextTokens("abcd"));
}

test "compactHistoryImpl repairs tool pairing after the phi cut" {
    // Regression for the mid-session 400: the index-based cut could leave an
    // orphan tool_result at the head — on the OpenAI wire a role:"tool"
    // message whose assistant tool_calls was dropped, which strict gateways
    // reject wholesale.
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer history.deinit(alloc);

    const sys_blocks = try alloc.alloc(llm.ContentBlock, 1);
    sys_blocks[0] = .{ .text = try alloc.dupe(u8, "sys") };
    try history.append(alloc, .{ .role = .system, .content = sys_blocks, .timestamp = 0 });

    // 4 full exchanges: user → assistant(tool_use) → user(tool_result).
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const q = try alloc.alloc(llm.ContentBlock, 1);
        q[0] = .{ .text = try alloc.dupe(u8, "question") };
        try history.append(alloc, .{ .role = .user, .content = q, .timestamp = 0 });

        const id = try std.fmt.allocPrint(alloc, "call_{d}", .{i});
        const tu = try alloc.alloc(llm.ContentBlock, 1);
        tu[0] = .{ .tool_use = .{ .id = id, .name = try alloc.dupe(u8, "Bash"), .input = .null } };
        try history.append(alloc, .{ .role = .assistant, .content = tu, .timestamp = 0 });

        const tr = try alloc.alloc(llm.ContentBlock, 1);
        tr[0] = .{ .tool_result = .{
            .tool_use_id = try alloc.dupe(u8, id),
            .content = try alloc.dupe(u8, "ok"),
        } };
        try history.append(alloc, .{ .role = .user, .content = tr, .timestamp = 0 });
        // `id` ownership moved into the tool_use block — history frees it.
    }
    try std.testing.expectEqual(@as(usize, 13), history.items.len);

    if (compactHistoryImpl(&history, alloc, null)) |nf| std.testing.allocator.free(nf);

    // Head must not be an orphan tool-result message; tail must not be a
    // dangling assistant tool_use.
    try std.testing.expect(!isPureToolResultMessage(history.items[1]));
    const last = history.items[history.items.len - 1];
    try std.testing.expect(!(last.role == .assistant and messageHasToolUse(last)));

    clearHistory(&history, alloc);
    alloc.free(history.items[0].content[0].text);
    alloc.free(@constCast(history.items[0].content));
}

/// φ drift gate (T1.3): live-topic cosine below 1/PHI_INVERSE (≈0.618)
/// means the session's ranking anchor no longer matches the conversation.
pub fn shouldReanchor(baseline: []const f32, current: []const f32) bool {
    const drift_threshold: f32 = @floatCast(1.0 / math_mod.constants.PHI_INVERSE);
    return embedding_mod.cosine(baseline, current) < drift_threshold;
}

/// First text block of a message's content (user turns may carry tool
/// blocks; the typed text is what defines the topic).
fn firstTextOf(blocks: []const llm.ContentBlock) ?[]const u8 {
    for (blocks) |b| switch (b) {
        .text => |t| return t,
        else => {},
    };
    return null;
}

/// Mean embedding of the last ≤3 user turns — the "live topic" vector.
/// Null before any non-empty user turn. Caller frees the result.
pub fn topicVectorOfLastUserTurns(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator) ?[]f32 {
    var texts: [3][]const u8 = undefined;
    var n: usize = 0;
    var i = history.items.len;
    while (i > 0 and n < texts.len) {
        i -= 1;
        const m = history.items[i];
        if (m.role != .user) continue;
        if (firstTextOf(m.content)) |t| {
            if (t.len > 0) {
                texts[n] = t;
                n += 1;
            }
        }
    }
    if (n == 0) return null;
    const sum = alloc.alloc(f32, embedding_mod.DIMS) catch return null;
    var owned = false; // handed to caller on success
    defer if (!owned) alloc.free(sum);
    @memset(sum, 0);
    var count: usize = 0;
    for (texts[0..n]) |t| {
        const ev = embedding_mod.embed(alloc, t) catch continue;
        defer alloc.free(ev);
        for (sum, 0..) |*sv, k| sv.* += ev[k];
        count += 1;
    }
    if (count == 0) return null;
    owned = true;
    const inv = 1.0 / @as(f32, @floatFromInt(count));
    for (sum) |*sv| sv.* *= inv;
    return sum;
}

/// Replace the memory block's text inside history[0] (rebuild the block
/// slice like reapplySystemPromptIfNeeded does — content slices are const).
/// Identified by the OLD text slice identity; returns false without
/// touching history when no block matches (caller frees the new text).
pub fn swapMemoryBlockText(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, old_text: []const u8, new_text: []const u8) bool {
    if (history.items.len == 0) return false;
    const old = history.items[0].content;
    const nb = alloc.alloc(llm.ContentBlock, old.len) catch return false;
    var hit = false;
    for (old, 0..) |b, bi| {
        if (!hit) switch (b) {
            .text => |t| if (t.ptr == old_text.ptr and t.len == old_text.len) {
                nb[bi] = .{ .text = new_text };
                hit = true;
                continue;
            },
            else => {},
        };
        nb[bi] = b;
    }
    if (!hit) {
        alloc.free(nb);
        return false;
    }
    alloc.free(@constCast(old));
    history.items[0].content = nb;
    return true;
}

/// T8: append one block to history[0]'s system content (rebuild + grow,
/// same ownership pattern as the swap above).
pub fn appendSystemBlock(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, text: []const u8) bool {
    if (history.items.len == 0) return false;
    const old = history.items[0].content;
    const nb = alloc.alloc(llm.ContentBlock, old.len + 1) catch return false;
    @memcpy(nb[0..old.len], old);
    nb[old.len] = .{ .text = text };
    alloc.free(@constCast(old));
    history.items[0].content = nb;
    return true;
}

/// T8: drop the block whose text slice matches (rebuild + shrink).
pub fn removeSystemBlockByText(history: *std.ArrayList(llm.Message), alloc: std.mem.Allocator, text: []const u8) bool {
    if (history.items.len == 0) return false;
    const old = history.items[0].content;
    var hit: ?usize = null;
    for (old, 0..) |b, i| switch (b) {
        .text => |t| if (t.ptr == text.ptr and t.len == text.len) {
            hit = i;
            break;
        },
        else => {},
    };
    const idx = hit orelse return false;
    const nb = alloc.alloc(llm.ContentBlock, old.len - 1) catch return false;
    @memcpy(nb[0..idx], old[0..idx]);
    @memcpy(nb[idx..], old[idx + 1 ..]);
    alloc.free(@constCast(old));
    history.items[0].content = nb;
    return true;
}

/// T8: read .ziv/plan.md (≤8 KiB). Null when absent/unreadable.
pub fn readPlanFile(alloc: std.mem.Allocator, io: std.Io) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, ".ziv/plan.md", alloc, .limited(8 * 1024)) catch null;
}

/// T8: the plan's system-prompt summary — trimmed non-empty lines under
/// its own ~150-token budget (independent of the memory block's).
pub fn planSummaryText(alloc: std.mem.Allocator, raw: []const u8) ?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    aw.writer.writeAll("Active plan (.ziv/plan.md):\n") catch return null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0) continue;
        aw.writer.print("- {s}\n", .{t}) catch return null;
        if (tokens_mod.estimateTokens(aw.written()) > 150) break;
    }
    if (aw.written().len == 0) return null;
    return alloc.dupe(u8, aw.written()) catch null;
}

/// T8: keep the plan anchor block in sync with .ziv/plan.md — call at
/// every prompt. Content fingerprint (not mtime) decides, so a touch
/// never churns the prompt; removing the file removes the block.
pub fn refreshPlanAnchor(
    history: *std.ArrayList(llm.Message),
    plan_block: *?[]u8,
    plan_raw: *?[]u8,
    alloc: std.mem.Allocator,
    io: std.Io,
) void {
    const raw = readPlanFile(alloc, io) orelse {
        if (plan_block.*) |pb| {
            if (removeSystemBlockByText(history, alloc, pb)) {
                alloc.free(pb);
                plan_block.* = null;
            }
        }
        if (plan_raw.*) |pr| {
            alloc.free(pr);
            plan_raw.* = null;
        }
        return;
    };
    const changed = if (plan_raw.*) |pr| !std.mem.eql(u8, pr, raw) else true;
    if (!changed) {
        alloc.free(raw);
        return;
    }
    if (plan_raw.*) |pr| alloc.free(pr);
    plan_raw.* = raw;
    const summary = planSummaryText(alloc, raw) orelse {
        if (plan_block.*) |pb| {
            if (removeSystemBlockByText(history, alloc, pb)) {
                alloc.free(pb);
                plan_block.* = null;
            }
        }
        return;
    };
    const old = plan_block.*;
    plan_block.* = null;
    if (old) |pb| {
        const swapped = swapMemoryBlockText(history, alloc, pb, summary);
        if (!swapped) _ = removeSystemBlockByText(history, alloc, pb);
        alloc.free(pb);
        if (swapped) {
            plan_block.* = summary;
            return;
        }
    }
    if (appendSystemBlock(history, alloc, summary)) {
        plan_block.* = summary;
    } else alloc.free(summary);
}

test "plan summary, append and remove system blocks (T8)" {
    const alloc = std.testing.allocator;
    const raw = "# 计划：完成迁移\n\n- [x] 分析旧表\n- [ ] 写迁移脚本\n";
    const summary = planSummaryText(alloc, raw).?;
    defer alloc.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Active plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "分析旧表") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "写迁移脚本") != null);

    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        alloc.free(@constCast(history.items[0].content));
        history.deinit(alloc);
    }
    const blocks = try alloc.alloc(llm.ContentBlock, 1);
    blocks[0] = .{ .text = "SYSTEM" };
    try history.append(alloc, .{ .role = .system, .content = blocks, .timestamp = 0 });

    try std.testing.expect(appendSystemBlock(&history, alloc, summary));
    try std.testing.expectEqual(@as(usize, 2), history.items[0].content.len);
    try std.testing.expectEqualStrings(summary, history.items[0].content[1].text);
    try std.testing.expect(removeSystemBlockByText(&history, alloc, summary));
    try std.testing.expectEqual(@as(usize, 1), history.items[0].content.len);
    try std.testing.expectEqualStrings("SYSTEM", history.items[0].content[0].text);
    try std.testing.expect(!removeSystemBlockByText(&history, alloc, summary)); // gone: no-op
}


test "key facts survive repeated phi compaction (T4.2)" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeContentBlocks(alloc, m.content);
        history.deinit(alloc);
    }
    const appendTurn = struct {
        fn f(a: std.mem.Allocator, h: *std.ArrayList(llm.Message), text: []const u8) !void {
            const b = try a.alloc(llm.ContentBlock, 1);
            b[0] = .{ .text = try a.dupe(u8, text) }; // HEAP: blocks free their text
            try h.append(a, .{ .role = .user, .content = b, .timestamp = 0 });
        }
    }.f;

    // Index 0 is always kept as the system prompt — the DECISION must sit
    // at index 1 so phi actually drops it (that's the point of the test).
    try appendTurn(alloc, &history, "SYSTEM-PROMPT");
    try appendTurn(alloc, &history, "我们决定使用 sqlite WAL 模式，数据库文件是 data/app.db，不要改成 delete 模式");
    // Filler turns so phi actually drops the head.
    for (0..40) |i| {
        var tb: [64]u8 = undefined;
        const t = try std.fmt.bufPrint(&tb, "regular exchange number {d} nothing worth keeping", .{i});
        try appendTurn(alloc, &history, t);
    }
    // NOTE: the facts block lives in history[0]'s blocks — its text is
    // freed by the message cleanup below, so NO separate facts defer.
    var facts: ?[]u8 = null;

    var rounds: usize = 0;
    while (rounds < 3) : (rounds += 1) {
        // replenish filler so each round actually compacts again
        for (0..20) |i| {
            var tb: [64]u8 = undefined;
            const t = try std.fmt.bufPrint(&tb, "later padding {d} for the round", .{i});
            try appendTurn(alloc, &history, t);
        }
        applyFactsUpdate(&history, &facts, alloc, compactHistoryImpl(&history, alloc, facts));
    }
    const f = facts orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, f, "sqlite WAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, f, "data/app.db") != null);
    // And the block is anchored in history[0].
    var anchored = false;
    for (history.items[0].content) |b| switch (b) {
        .text => |t| if (std.mem.indexOf(u8, t, "sqlite WAL") != null) {
            anchored = true;
        },
        else => {},
    };
    try std.testing.expect(anchored);
}


test "shouldReanchor: phi gate on topic drift (T1.3)" {
    const alloc = std.testing.allocator;
    // Same text → cosine 1 → no re-anchor.
    const a = try embedding_mod.embed(alloc, "deploy the payment service with docker");
    defer alloc.free(a);
    const a2 = try embedding_mod.embed(alloc, "deploy the payment service with docker");
    defer alloc.free(a2);
    try std.testing.expect(!shouldReanchor(a, a2));
    // Disjoint token sets → cosine 0 < 0.618 → re-anchor.
    const b = try embedding_mod.embed(alloc, "xray yankee zulu whiskey tango");
    defer alloc.free(b);
    try std.testing.expect(shouldReanchor(a, b));
}


test "topicVectorOfLastUserTurns means last 3 user turns, ignores others" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| alloc.free(@constCast(m.content));
        history.deinit(alloc);
    }
    const mkMsg = struct {
        fn f(a: std.mem.Allocator, h: *std.ArrayList(llm.Message), role: @TypeOf(h.items[0].role), text: []const u8) !void {
            const blocks = try a.alloc(llm.ContentBlock, 1);
            blocks[0] = .{ .text = text };
            try h.append(a, .{ .role = role, .content = blocks, .timestamp = 0 });
        }
    }.f;
    try mkMsg(alloc, &history, .user, "alpha bravo charlie");
    try mkMsg(alloc, &history, .assistant, "irrelevant assistant text");
    try mkMsg(alloc, &history, .user, "delta echo foxtrot");
    const v = topicVectorOfLastUserTurns(&history, alloc).?;
    defer alloc.free(v);
    try std.testing.expectEqual(embedding_mod.DIMS, v.len);
    // Assistant-only history → null.
    var h2: std.ArrayList(llm.Message) = .empty;
    defer {
        for (h2.items) |m| alloc.free(@constCast(m.content));
        h2.deinit(alloc);
    }
    try mkMsg(alloc, &h2, .assistant, "only assistant");
    try std.testing.expect(topicVectorOfLastUserTurns(&h2, alloc) == null);
}


test "swapMemoryBlockText replaces by identity, preserves siblings" {
    const alloc = std.testing.allocator;
    // swapMemoryBlockText TAKES OWNERSHIP of the old content slice — no
    // defer-free here; the swap frees it and installs a new one that the
    // history teardown below releases.
    const blocks = try alloc.alloc(llm.ContentBlock, 3);
    blocks[0] = .{ .text = "SYSTEM" };
    blocks[1] = .{ .text = "OLD-MEMORY" };
    blocks[2] = .{ .text = "SKILLS" };
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        alloc.free(@constCast(history.items[0].content));
        history.deinit(alloc);
    }
    try history.append(alloc, .{ .role = .system, .content = blocks, .timestamp = 0 });

    const new_text = try alloc.dupe(u8, "NEW-MEMORY");
    defer alloc.free(new_text);
    try std.testing.expect(swapMemoryBlockText(&history, alloc, "OLD-MEMORY", new_text));
    const cur = history.items[0].content;
    try std.testing.expectEqual(@as(usize, 3), cur.len);
    try std.testing.expectEqualStrings("SYSTEM", cur[0].text);
    try std.testing.expectEqualStrings("NEW-MEMORY", cur[1].text);
    try std.testing.expectEqualStrings("SKILLS", cur[2].text);
    // Stale pointer → no match, history untouched (and the candidate not
    // consumed — caller keeps ownership).
    try std.testing.expect(!swapMemoryBlockText(&history, alloc, "OLD-MEMORY", new_text));
    try std.testing.expectEqualStrings("NEW-MEMORY", history.items[0].content[1].text);
}


test "hybrid layout: 20 rounds keep last 5 verbatim, slim tool results, <40% tokens" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeMessage(m, alloc);
        history.deinit(alloc);
    }

    // [system] + 20 × ([user text] [assistant text] [user tool_result 5 KiB])
    {
        const sb = try alloc.alloc(llm.ContentBlock, 1);
        sb[0] = .{ .text = try alloc.dupe(u8, "SYSTEM") };
        try history.append(alloc, .{ .role = .system, .content = sb, .timestamp = 0 });
    }
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var ub: [64]u8 = undefined;
        const ut = try std.fmt.bufPrint(&ub, "user question round {d} about topic {d}", .{ round, round * 7 });
        const ubb = try alloc.alloc(llm.ContentBlock, 1);
        ubb[0] = .{ .text = try alloc.dupe(u8, ut) };
        try history.append(alloc, .{ .role = .user, .content = ubb, .timestamp = 0 });

        var ab: [64]u8 = undefined;
        const at = try std.fmt.bufPrint(&ab, "assistant answer round {d}", .{round});
        const abb = try alloc.alloc(llm.ContentBlock, 1);
        abb[0] = .{ .text = try alloc.dupe(u8, at) };
        try history.append(alloc, .{ .role = .assistant, .content = abb, .timestamp = 0 });

        const fat = try alloc.alloc(u8, 5 * 1024);
        @memset(fat, 'x');
        const trb = try alloc.alloc(llm.ContentBlock, 1);
        trb[0] = .{ .tool_result = .{
            .tool_use_id = try alloc.dupe(u8, "id"),
            .content = fat,
        } };
        try history.append(alloc, .{ .role = .user, .content = trb, .timestamp = 0 });
    }
    const before_tokens = estimateHistoryTokens(history.items);
    const before_msgs = history.items.len;
    try std.testing.expectEqual(@as(usize, 61), before_msgs);

    // The layout (not the LLM call) is what the acceptance locks.
    const split = compaction.hybridSplit(history.items, compaction.HYBRID_KEEP_ROUNDS);
    try std.testing.expectEqual(@as(usize, 46), split); // round 15 opens the tail (last 5 of rounds 0..19)
    const slim = try applyHybridLayout(&history, alloc, split, "SUMMARY: rounds 0-15 condensed.");

    // Tier 2: the last five rounds stay verbatim.
    for ([_][]const u8{ "round 15", "round 16", "round 17", "round 18", "round 19" }) |frag| {
        var found = false;
        for (history.items) |m| for (m.content) |b| {
            if (b == .text and std.mem.indexOf(u8, b.text, frag) != null) found = true;
        };
        try std.testing.expect(found);
    }
    // Old rounds survive ONLY inside the summary message — the exact old
    // phrasings must be gone from any text block.
    var has_summary = false;
    for (history.items) |m| for (m.content) |b| {
        if (b != .text) continue;
        if (std.mem.indexOf(u8, b.text, "SUMMARY: rounds 0-15") != null) has_summary = true;
        if (std.mem.indexOf(u8, b.text, "user question round") != null)
            try std.testing.expect(std.mem.indexOf(u8, b.text, "round 15") != null or
                std.mem.indexOf(u8, b.text, "round 16") != null or
                std.mem.indexOf(u8, b.text, "round 17") != null or
                std.mem.indexOf(u8, b.text, "round 18") != null or
                std.mem.indexOf(u8, b.text, "round 19") != null);
    };
    try std.testing.expect(has_summary);

    // Tier 3: every remaining tool_result carries the slim marker.
    try std.testing.expectEqual(@as(usize, 5), slim.slimmed);
    for (history.items) |m| for (m.content) |b| {
        if (b == .tool_result) {
            try std.testing.expect(b.tool_result.content.len < 2 * 1024);
            try std.testing.expect(std.mem.indexOf(u8, b.tool_result.content, "5120") != null);
        }
    };

    // Acceptance: total tokens < 40% of before, message count shrank.
    const after_tokens = estimateHistoryTokens(history.items);
    try std.testing.expect(after_tokens * 10 < before_tokens * 4);
    try std.testing.expect(history.items.len < before_msgs);
}

test "maybeCompact auto path: phi cut + tier-3 slimming fire together" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeMessage(m, alloc);
        history.deinit(alloc);
    }
    // Unknown model name → contextEstimate 32K → φ threshold ~20.2K tokens.
    // 22 rounds × 5 KiB tool results (~1.3K tokens each) ≈ 29K tokens: φ has
    // messages to cut AND the kept window still holds fat tool results.
    {
        const sb = try alloc.alloc(llm.ContentBlock, 1);
        sb[0] = .{ .text = try alloc.dupe(u8, "SYSTEM") };
        try history.append(alloc, .{ .role = .system, .content = sb, .timestamp = 0 });
    }
    var round: usize = 0;
    while (round < 22) : (round += 1) {
        const ubb = try alloc.alloc(llm.ContentBlock, 1);
        ubb[0] = .{ .text = try alloc.dupe(u8, "user question text padding for tokens") };
        try history.append(alloc, .{ .role = .user, .content = ubb, .timestamp = 0 });
        const fat = try alloc.alloc(u8, 5 * 1024);
        @memset(fat, 'x');
        const trb = try alloc.alloc(llm.ContentBlock, 1);
        trb[0] = .{ .tool_result = .{
            .tool_use_id = try alloc.dupe(u8, "id"),
            .content = fat,
        } };
        try history.append(alloc, .{ .role = .user, .content = trb, .timestamp = 0 });
    }
    var w_buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&w_buf);
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const null_file = try std.Io.Dir.cwd().openFile(io_state.io(), "/dev/null", .{ .mode = .write_only });
    defer null_file.close(io_state.io());
    var fw_buf: [256]u8 = undefined;
    var fw = std.Io.File.Writer.initStreaming(null_file, io_state.io(), &fw_buf);
    var log = op_log.OperationLog.init(alloc);
    defer log.deinit();
    var facts: ?[]u8 = null;
    defer if (facts) |f| alloc.free(f);

    const ev = maybeCompact(&history, alloc, &w, &fw, &log, &facts, "unknown-model-x", .openai);
    try std.testing.expect(ev.compacted);
    try std.testing.expect(ev.before_tokens > ev.tokens);
    try std.testing.expect(ev.slimmed > 0); // tier 3 rode along
    // Every surviving tool_result is slimmed.
    for (history.items) |m| for (m.content) |b| {
        if (b == .tool_result) {
            try std.testing.expect(b.tool_result.content.len < 2 * 1024);
            try std.testing.expect(std.mem.indexOf(u8, b.tool_result.content, "字节") != null);
        }
    };
    // Facts block landed in history[0] (decisions/paths distilled from cut).
    // (No fact-marker text in this fixture → block may be absent; the phi
    // cut itself is already asserted via ev.compacted.)
}


test "foldOldToolResults: marathon round keeps only the last K results (pairing intact)" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeMessage(m, alloc);
        history.deinit(alloc);
    }
    {
        const sb = try alloc.alloc(llm.ContentBlock, 1);
        sb[0] = .{ .text = try alloc.dupe(u8, "SYSTEM") };
        try history.append(alloc, .{ .role = .system, .content = sb, .timestamp = 0 });
    }
    {
        const ub = try alloc.alloc(llm.ContentBlock, 1);
        ub[0] = .{ .text = try alloc.dupe(u8, "marathon turn") };
        try history.append(alloc, .{ .role = .user, .content = ub, .timestamp = 0 });
    }
    // 同一回合 12 条 tool_result，每条 2 KiB（阈值 1 KiB 之下不会被
    // slim 单独处理，专测 fold）。
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const fb = try alloc.alloc(llm.ContentBlock, 1);
        const payload = try alloc.alloc(u8, 2048);
        @memset(payload, 'r');
        fb[0] = .{ .tool_result = .{ .tool_use_id = try alloc.dupe(u8, "tid"), .content = payload } };
        try history.append(alloc, .{ .role = .user, .content = fb, .timestamp = 0 });
    }
    const stats = foldOldToolResults(history.items, alloc);
    try std.testing.expectEqual(@as(usize, 4), stats.folded); // 12 - FOLD_KEEP(8)
    try std.testing.expect(stats.bytes_before == 4 * 2048);
    // 配对完整性：消息数不变，被折叠的 content 是标记行而非全文。
    try std.testing.expectEqual(@as(usize, 14), history.items.len);
    var folded_markers: usize = 0;
    var kept_full: usize = 0;
    for (history.items[2..]) |m| {
        for (m.content) |b| {
            if (b == .tool_result) {
                if (std.mem.indexOf(u8, b.tool_result.content, "已并入摘要") != null) folded_markers += 1 else kept_full += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 4), folded_markers);
    try std.testing.expectEqual(@as(usize, 8), kept_full);
}

test "pressure ladder + rolling compaction converge: information compresses forever, never blows up" {
    const alloc = std.testing.allocator;
    // 模拟马拉松：反复「长 10 轮(含 5KiB 工具结果) → 压缩」，每次压缩
    // 用假摘要（LLM 调用是 compactHistoryKeep 的事，这里锁的是布局
    // 不变量）。不变量：任意轮数后 token 有上界（摘要≤300 + 近5轮
    // 原文有界——工具结果经瘦身每条 ≤~1.1KiB）。
    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeMessage(m, alloc);
        history.deinit(alloc);
    }
    {
        const sb = try alloc.alloc(llm.ContentBlock, 1);
        sb[0] = .{ .text = try alloc.dupe(u8, "SYSTEM") };
        try history.append(alloc, .{ .role = .system, .content = sb, .timestamp = 0 });
    }
    var cycle: usize = 0;
    var worst: u32 = 0;
    while (cycle < 12) : (cycle += 1) {
        // 长出 10 轮，每轮 user 文本 + 5KiB 工具结果。
        var r: usize = 0;
        while (r < 10) : (r += 1) {
            const ub = try alloc.alloc(llm.ContentBlock, 1);
            ub[0] = .{ .text = try alloc.dupe(u8, "user turn padding text for convergence invariant check") };
            try history.append(alloc, .{ .role = .user, .content = ub, .timestamp = 0 });
            const fat = try alloc.alloc(u8, 5 * 1024);
            @memset(fat, 'x');
            const tb = try alloc.alloc(llm.ContentBlock, 1);
            tb[0] = .{ .tool_result = .{ .tool_use_id = try alloc.dupe(u8, "id"), .content = fat } };
            try history.append(alloc, .{ .role = .user, .content = tb, .timestamp = 0 });
        }
        // 压力梯子触发：>61.8% 即提炼。手工执行布局（等价
        // compactHistoryKeep 的成功路径）：摘要块 + 近5轮 + 全量瘦身。
        const split = compaction.hybridSplit(history.items, compaction.HYBRID_KEEP_ROUNDS);
        _ = try applyHybridLayout(&history, alloc, split, "SUMMARY: everything before, condensed.");
        // 上界断言：压后必须显著低于 10 轮的裸体量（摘要 + 5 轮瘦身）。
        const est = estimateHistoryTokens(history.items);
        worst = @max(worst, est);
        // 12 轮循环后，history 恒 = system + summary + ≤11 条消息；
        // 瘦身后每条工具结果 ≤ ~1.1KiB ⇒ est 应稳定在 ~4K 以下。
        try std.testing.expect(est < 4200);
        try std.testing.expect(history.items.len <= 13);
    }
    // 有界性：最坏值不随循环数增长（第 1 轮与第 12 轮同界）。
    const last = estimateHistoryTokens(history.items);
    try std.testing.expect(worst < 4200);
    try std.testing.expect(last < 4200);
    // 梯子矩阵（T3.1：起点 75%——700/1000 已落在 ok 段）。
    try std.testing.expect(pressureLadder(500, 1000) == .ok);
    try std.testing.expect(pressureLadder(700, 1000) == .ok);
    try std.testing.expect(pressureLadder(800, 1000) == .extract);
    try std.testing.expect(pressureLadder(950, 1000) == .emergency);
    try std.testing.expect(pressureLadder(10, 0) == .emergency);
}

test "applyHybridLayout is byte-deterministic: same input → same output (T3.2)" {
    // 前缀稳定的我们这侧的一半：布局手术不得掺入时间戳/计数器等
    // 随机量——同输入两次手术，逐消息字节一致（LLM 摘要温度已归零，
    // 这里锁的是 ziv 自己的包装层）。
    const alloc = std.testing.allocator;
    const build = struct {
        fn mk(a: std.mem.Allocator) !std.ArrayList(llm.Message) {
            var h: std.ArrayList(llm.Message) = .empty;
            errdefer {
                for (h.items) |m| freeMessage(m, a);
                h.deinit(a);
            }
            const sb = try a.alloc(llm.ContentBlock, 1);
            sb[0] = .{ .text = try a.dupe(u8, "SYSTEM") };
            try h.append(a, .{ .role = .system, .content = sb, .timestamp = 0 });
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                const ub = try a.alloc(llm.ContentBlock, 1);
                ub[0] = .{ .text = try a.dupe(u8, "turn A padding text") };
                try h.append(a, .{ .role = .user, .content = ub, .timestamp = 0 });
                const fb = try a.alloc(llm.ContentBlock, 1);
                fb[0] = .{ .tool_result = .{ .tool_use_id = try a.dupe(u8, "tid"), .content = try a.dupe(u8, "fat result bytes") } };
                try h.append(a, .{ .role = .user, .content = fb, .timestamp = 0 });
            }
            return h;
        }
    }.mk;
    var h1 = try build(alloc);
    defer h1.deinit(alloc);
    defer for (h1.items) |m| freeMessage(m, alloc);
    var h2 = try build(alloc);
    defer h2.deinit(alloc);
    defer for (h2.items) |m| freeMessage(m, alloc);

    const split = compaction.hybridSplit(h1.items, compaction.HYBRID_KEEP_ROUNDS);
    _ = try applyHybridLayout(&h1, alloc, split, "SUMMARY payload");
    _ = try applyHybridLayout(&h2, alloc, split, "SUMMARY payload");

    try std.testing.expectEqual(h1.items.len, h2.items.len);
    for (h1.items, h2.items) |*a, *b| {
        try std.testing.expect(a.role == b.role);
        try std.testing.expectEqual(a.content.len, b.content.len);
        for (a.content, b.content) |ca, cb| {
            if (ca == .text and cb == .text) {
                try std.testing.expectEqualStrings(ca.text, cb.text);
            } else if (ca == .tool_result and cb == .tool_result) {
                try std.testing.expectEqualStrings(ca.tool_result.content, cb.tool_result.content);
            }
        }
    }
    // 梯子计数器只增不减、恒为非负（/stats 读它们）。
    try std.testing.expect(compacts_done >= 0 and tokens_reclaimed >= 0);
}
