/// Message compaction — two strategies for freeing context window:
///   - `phi_condense` (truncation): drop the oldest messages down to the φ
///     target, keeping the system prompt. Pure math + history surgery, no
///     LLM call — lives in repl.zig (compactHistoryImpl, maybeCompact,
///     /compact phi).
///   - `summarize` (Claude-style): the LLM summarizes the conversation and
///     the summary replaces the history, so context is condensed instead of
///     dropped. This module provides the summary instruction and transcript
///     renderer; the LLM call and history surgery live in repl.zig (/compact).
/// Both strategies share the φ threshold math below.
const std = @import("std");
const provider = @import("provider.zig");
const math_mod = @import("../math/mod.zig");

pub const CompactionStrategy = enum {
    summarize,
    phi_condense,
    hybrid,
};

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
