/// Message compaction — three strategies for freeing context window:
///   - `phi_condense` (truncation): drop the oldest messages down to the φ
///     target, keeping the system prompt. Pure math + history surgery, no
///     LLM call — lives in turn/history.zig (compactHistoryImpl,
///     maybeCompact, /compact phi).
///   - `summarize` (Claude-style): the LLM summarizes the conversation and
///     the summary replaces the history, so context is condensed instead of
///     dropped. This module provides the summary instruction and transcript
///     renderer; the LLM call and history surgery live in turn/history.zig
///     (/compact).
///   - `hybrid` (P2, design D4): three tiers — the OLD segment is LLM-
///     summarized, the most recent K ROUNDS stay verbatim (round-anchored,
///     never split mid-exchange), and oversized tool_results in the kept
///     window are slimmed to a head + byte-count marker. The summary is no
///     longer all-or-nothing. Bounds math lives here (hybridSplit); the
///     surgery is applyHybridLayout in turn/history.zig.
/// All strategies share the φ threshold math below.
const std = @import("std");
const provider = @import("provider.zig");
const math_mod = @import("../math/mod.zig");

pub const CompactionStrategy = enum {
    summarize,
    phi_condense,
    /// Auto-compaction flavor since P2: φ truncation PLUS tier-3 tool-result
    /// slimming over the kept window (no LLM dependency — the emergency path
    /// must work with the gateway down).
    phi_slim,
    hybrid,

    pub fn label(self: CompactionStrategy) []const u8 {
        return switch (self) {
            .summarize => "summarize",
            .phi_condense => "phi",
            .phi_slim => "phi+slim",
            .hybrid => "hybrid",
        };
    }
};

/// Hybrid tier-2: how many trailing ROUNDS stay verbatim (a round is
/// user-anchored: the user message plus every assistant/tool message up to
/// the next user message). Roadmap acceptance: 20-round conversation keeps
/// the last 5 rounds.
pub const HYBRID_KEEP_ROUNDS: usize = 5;

/// 2026-11-09（用户报「/compact 后仍 49%」取证后的硬上界）：保留窗的
/// token 帽——5 个回合若超此体量则从尾部截短；回合数不足（单回合
/// 马拉松：几百次工具调用全在一个 round 里）时以此为兜底切出保留
/// 窗，旧段照样进摘要。原先「rounds < keep → 保留全部」对单回合
/// 马拉松等于压缩罢工。
pub const KEEP_TAIL_TOKEN_CAP: u32 = 12_000;

/// Tier-3: a tool_result larger than this is slimmed IN HISTORY to
/// TOOL_SLIM_HEAD bytes + a byte-count marker. The display layer (/last)
/// keeps full text independently — this saves request tokens only.
/// 2026-11-08 收紧（用户反馈「压完上下文还是很长」）：阈值 4 KiB→1 KiB、
/// 保留头 1024→512。显示层不受影响（/last 环、LastTools 独立持有全文）。
pub const TOOL_SLIM_THRESHOLD: usize = 1 * 1024;
pub const TOOL_SLIM_HEAD: usize = 512;

/// Marker appended to a slimmed tool_result: `[截断，完整输出 N 字节]`.
pub fn toolSlimMarker(buf: []u8, original_bytes: usize) []const u8 {
    return std.fmt.bufPrint(buf, "\n[截断，完整输出 {d} 字节]\n", .{original_bytes}) catch "";
}

/// Round-anchored three-tier split for the hybrid strategy.
/// Returns `summarize_to`: messages [1, summarize_to) form the LLM-summarized
/// old segment, [summarize_to, len) is the verbatim tail holding exactly
/// `keep_rounds` user-anchored rounds (or the whole conversation when there
/// are fewer — then 1 is returned: nothing to summarize).
/// A round anchor is a user message whose first block is TEXT: tool results
/// ride on user-role messages (Anthropic convention), and they belong to the
/// round that called the tool — the boundary therefore never separates a
/// tool_result from its tool_use across tiers.
pub fn hybridSplit(messages: []const provider.Message, keep_rounds: usize) usize {
    if (messages.len <= 1) return 1;
    // Index of the message that starts the keep_rounds-th-from-last round.
    var rounds_seen: usize = 0;
    var acc: u32 = 0;
    var capped_start: ?usize = null; // token 帽先到时的锚点（i+1 起保留）
    var i = messages.len;
    while (i > 1) {
        i -= 1;
        const m = messages[i];
        acc += messageTokens(m);
        if (acc > KEEP_TAIL_TOKEN_CAP and capped_start == null) {
            capped_start = @min(i + 1, messages.len - 1);
        }
        if (m.role == .user and m.content.len > 0 and m.content[0] == .text) {
            rounds_seen += 1;
            if (rounds_seen == keep_rounds) {
                // A bare user message at index 0 would mean index 0 is not the
                // system prompt — still summarize from 1, never drop the head.
                const round_start = @max(i, 1);
                // 回合锚与 token 帽取更小保留窗者（帽先到 = 肥回合截短）。
                if (capped_start) |cs| return @max(round_start, cs);
                return round_start;
            }
        }
    }
    // 回合数不足（单回合马拉松：几百次工具调用全在一个 round）——原先
    // 这里返回 1 = 压缩罢工。现在 token 帽兜底切窗，旧段照样进摘要；
    // 从未超帽的小历史整体保留（确实无需压缩）。
    if (capped_start) |cs| return cs;
    return 1;
}

fn messageTokens(m: provider.Message) u32 {
    var acc2: u32 = 0;
    for (m.content) |b| switch (b) {
        // 字节/3 ≈ token 粗估（对 CJK 偏保守，帽子控制足够）。
        .text => |t| acc2 += 64 + @as(u32, @intCast(t.len / 3)),
        .tool_result => |tr| acc2 += 64 + @as(u32, @intCast(tr.content.len / 3)),
        .tool_use => |tu| acc2 += 64 + @as(u32, @intCast(jsonValueSize(tu.input) / 3)),
        else => acc2 += 16,
    };
    return acc2;
}

/// JSON Value 的字节量粗估（object/array 深度遍历，字符串按原文）。
pub fn jsonValueSize(v: std.json.Value) usize {
    return switch (v) {
        .string => |s| s.len + 2,
        .object => |o| blk: {
            var n: usize = 8;
            var it = o.iterator();
            while (it.next()) |e| n += e.key_ptr.len + jsonValueSize(e.value_ptr.*) + 4;
            break :blk n;
        },
        .array => |a| blk: {
            var n: usize = 4;
            for (a.items) |it| n += jsonValueSize(it) + 2;
            break :blk n;
        },
        else => 8,
    };
}

pub const CompactionResult = union(enum) {
    compacted: struct {
        messages_removed: usize,
        tokens_saved: u32,
    },
    no_change,
};

/// Check if compaction is needed based on phi threshold (61.8%).
pub fn needsCompaction(current_tokens: u32, max_tokens: u32) bool {
    const threshold = math_mod.condensationTarget(@as(usize, max_tokens));
    return current_tokens > @as(u32, @intCast(threshold));
}

/// Calculate how many messages to keep using phi condensation target.
pub fn condensationTarget(message_count: usize) usize {
    return math_mod.condensationTarget(message_count);
}

/// System instruction for the summarize strategy (/compact). The summary
/// REPLACES the conversation, so it must carry everything needed to
/// continue the work without the original messages.
pub const SUMMARY_INSTRUCTION =
    \\You are a precise conversation summarizer. Summarize the conversation below so that work can continue with the summary alone, in place of the full history. Respond in the conversation's dominant language. Use exactly these numbered sections:
    \\
    \\1. Primary Request and Intent:
    \\2. Key Technical Concepts:
    \\3. Files and Code Sections:
    \\4. Errors and fixes:
    \\5. Problem Solving:
    \\6. Pending Tasks:
    \\7. Current Work:
    \\8. Optional Next Step:
    \\
    \\Be specific and information-dense: exact file paths, commands, APIs, decisions and their reasons, and concrete results. Prefer facts over prose. Do not preface the summary with any commentary.
    \\
    \\Length budget: at most ~600 words total. Compress aggressively — the summary REPLACES the history, and a bloated summary defeats its own purpose. Cut anything the next step does not strictly need.
;

/// Render conversation messages as a role-labeled transcript for the
/// summarizer. Thinking blocks are omitted (internal reasoning); tool_use
/// and tool_result blocks render inline so tool activity survives compaction.
/// Caller owns the returned slice.
pub fn renderTranscript(alloc: std.mem.Allocator, messages: []const provider.Message) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const pw = &aw.writer;
    for (messages) |msg| {
        const label = switch (msg.role) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
        for (msg.content) |block| {
            switch (block) {
                .text => |t| try pw.print("[{s}] {s}\n", .{ label, t }),
                .thinking => {},
                .tool_use => |tu| {
                    const input_json = std.json.Stringify.valueAlloc(alloc, tu.input, .{}) catch "{}";
                    defer alloc.free(input_json);
                    try pw.print("[{s}] calls tool {s} {s}\n", .{ label, tu.name, input_json });
                },
                .tool_result => |tr| {
                    const tag: []const u8 = if (tr.is_error) "tool error" else "tool result";
                    try pw.print("[{s}] {s}\n", .{ tag, tr.content });
                },
            }
        }
    }
    var list = aw.toArrayList();
    return list.toOwnedSlice(alloc);
}

test "needsCompaction" {
    // Below phi threshold (61.8%)
    try std.testing.expect(!needsCompaction(500, 1000));
    // Above phi threshold
    try std.testing.expect(needsCompaction(700, 1000));
}

test "condensationTarget" {
    try std.testing.expectEqual(@as(usize, 61), condensationTarget(100));
    try std.testing.expectEqual(@as(usize, 618), condensationTarget(1000));
}

test "hybridSplit locks the three-tier boundaries" {
    const alloc = std.testing.allocator;
    // 20 rounds, 3 messages each: [sys] then per round (user-text, assistant,
    // user-tool_result). sys occupies index 0; round r's user msg sits at
    // 1 + 3r. Keeping the last 5 rounds must split exactly on round 16's
    // user message: 1 + 3*15 = 46.
    const text_blocks = try alloc.alloc(provider.ContentBlock, 1);
    defer alloc.free(text_blocks);
    text_blocks[0] = .{ .text = "x" };
    const tr_blocks = try alloc.alloc(provider.ContentBlock, 1);
    defer {
        alloc.free(@constCast(tr_blocks[0].tool_result.tool_use_id));
        alloc.free(@constCast(tr_blocks[0].tool_result.content));
        alloc.free(tr_blocks);
    }
    tr_blocks[0] = .{ .tool_result = .{
        .tool_use_id = @constCast(try alloc.dupe(u8, "t0")),
        .content = @constCast(try alloc.dupe(u8, "r")),
    } };
    var msgs: [61]provider.Message = undefined;
    msgs[0] = .{ .role = .system, .content = text_blocks, .timestamp = 0 };
    for (1..61) |i| {
        msgs[i] = .{
            .role = if (i % 3 == 1) .user else if (i % 3 == 2) .assistant else .user,
            .content = if (i % 3 == 0) tr_blocks else text_blocks,
            .timestamp = 0,
        };
    }
    try std.testing.expectEqual(@as(usize, 46), hybridSplit(&msgs, 5));

    // ≤ keep_rounds rounds 且不超 token 帽：保留全部（确实小）。
    try std.testing.expectEqual(@as(usize, 1), hybridSplit(msgs[0..1], 5));
    try std.testing.expectEqual(@as(usize, 1), hybridSplit(msgs[0..13], 5)); // 4 rounds
    // Round anchor must NOT be a tool-result user message: cutting before
    // round 20's text user message leaves round 19's tool message as the
    // last user-role message — the split still lands on a TEXT user message.
    try std.testing.expectEqual(@as(usize, 43), hybridSplit(msgs[0..58], 5));
}

test "hybridSplit: fat single-round marathon no longer refuses to compact (2026-11-09)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // 单回合马拉松：sys + user + N 条大 result（每条 ~6KB → token 超 12K 帽）。
    // 旧行为：rounds(1) < 5 → 返回 1 = 压缩罢工。新行为：token 帽兜底
    // 切窗，返回 >1 的锚点（旧段可进摘要）。
    const text_blocks = try alloc.alloc(provider.ContentBlock, 1);
    text_blocks[0] = .{ .text = "marathon" };
    const fat = try alloc.alloc(u8, 6 * 1024);
    @memset(fat, 'x');
    var msgs: std.ArrayList(provider.Message) = .empty;
    try msgs.append(alloc, .{ .role = .system, .content = text_blocks, .timestamp = 0 });
    try msgs.append(alloc, .{ .role = .user, .content = text_blocks, .timestamp = 0 });
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const tb = try alloc.alloc(provider.ContentBlock, 1);
        tb[0] = .{ .tool_result = .{ .tool_use_id = "t", .content = fat } };
        try msgs.append(alloc, .{ .role = .user, .content = tb, .timestamp = 0 });
    }
    const split = hybridSplit(msgs.items, 5);
    try std.testing.expect(split > 1); // 不再罢工
    try std.testing.expect(split < msgs.items.len); // 保留窗非空
    // 保留窗体量有界：帽 12K tokens × 3B/token = 36KB，12 条 6KB = 72KB
    // 全量必超帽——锚点应切在尾部一段。
    try std.testing.expect(msgs.items.len - split < 12);
}

test "toolSlimMarker carries the original byte count" {
    var buf: [64]u8 = undefined;
    const m = toolSlimMarker(&buf, 16384);
    try std.testing.expect(std.mem.indexOf(u8, m, "16384") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "截断") != null);
}

test "renderTranscript labels roles and includes tool activity" {
    const alloc = std.testing.allocator;

    var input_obj: std.json.ObjectMap = .empty;
    defer input_obj.deinit(alloc);
    try input_obj.put(alloc, "path", .{ .string = "/tmp/a" });

    const blocks1 = try alloc.alloc(provider.ContentBlock, 1);
    blocks1[0] = .{ .text = try alloc.dupe(u8, "read /tmp/a") };
    const blocks2 = try alloc.alloc(provider.ContentBlock, 1);
    blocks2[0] = .{ .tool_use = .{
        .id = try alloc.dupe(u8, "t1"),
        .name = try alloc.dupe(u8, "FileRead"),
        .input = .{ .object = input_obj },
    } };
    const blocks3 = try alloc.alloc(provider.ContentBlock, 2);
    blocks3[0] = .{ .thinking = try alloc.dupe(u8, "hidden reasoning") };
    blocks3[1] = .{ .tool_result = .{
        .tool_use_id = try alloc.dupe(u8, "t1"),
        .content = try alloc.dupe(u8, "file contents here"),
    } };
    const msgs = [_]provider.Message{
        .{ .role = .user, .content = blocks1, .timestamp = 1 },
        .{ .role = .assistant, .content = blocks2, .timestamp = 2 },
        .{ .role = .user, .content = blocks3, .timestamp = 3 },
    };

    const out = try renderTranscript(alloc, &msgs);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "[user] read /tmp/a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[assistant] calls tool FileRead {\"path\":\"/tmp/a\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[tool result] file contents here\n") != null);
    // Thinking blocks must not leak into the transcript.
    try std.testing.expect(std.mem.indexOf(u8, out, "hidden reasoning") == null);

    alloc.free(blocks1[0].text);
    alloc.free(blocks1);
    alloc.free(blocks2[0].tool_use.id);
    alloc.free(blocks2[0].tool_use.name);
    alloc.free(blocks2);
    alloc.free(blocks3[0].thinking);
    alloc.free(blocks3[1].tool_result.tool_use_id);
    alloc.free(blocks3[1].tool_result.content);
    alloc.free(blocks3);
}
