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
    const summarize_to = compaction.hybridSplit(history.items, compaction.HYBRID_KEEP_ROUNDS);
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
        .max_tokens = @min(switcher.settings.max_tokens, 2048),
        .temperature = 0.3,
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

/// Hybrid surgery (pure, no LLM): rebuild history as
/// [system prompt (kept — clearHistory preserves index 0)] +
/// [summary-as-user-message] + [verbatim tail from summarize_to], then slim
/// oversized tool_results everywhere. The tail is duped out before the
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
