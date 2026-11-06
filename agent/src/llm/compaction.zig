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

/// Tier-3: a tool_result larger than this is slimmed IN HISTORY to
/// TOOL_SLIM_HEAD bytes + a byte-count marker. The display layer (/last)
/// keeps full text independently — this saves request tokens only.
pub const TOOL_SLIM_THRESHOLD: usize = 4 * 1024;
pub const TOOL_SLIM_HEAD: usize = 1024;

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
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const m = messages[i];
        if (m.role != .user) continue;
        if (m.content.len == 0 or m.content[0] != .text) continue; // tool-result message
        rounds_seen += 1;
        if (rounds_seen == keep_rounds) {
            // A bare user message at index 0 would mean index 0 is not the
            // system prompt — still summarize from 1, never drop the head.
            return @max(i, 1);
        }
    }
    // Fewer rounds than keep_rounds: keep everything verbatim.
    return 1;
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

    // ≤ keep_rounds rounds: nothing to summarize.
    try std.testing.expectEqual(@as(usize, 1), hybridSplit(msgs[0..1], 5));
    try std.testing.expectEqual(@as(usize, 1), hybridSplit(msgs[0..13], 5)); // 4 rounds
    // Round anchor must NOT be a tool-result user message: cutting before
    // round 20's text user message leaves round 19's tool message as the
    // last user-role message — the split still lands on a TEXT user message.
    try std.testing.expectEqual(@as(usize, 43), hybridSplit(msgs[0..58], 5));
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
