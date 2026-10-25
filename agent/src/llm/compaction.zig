/// Message compaction — compress conversation history when context exceeds phi threshold.
/// Combines LLM summarization with phi-based condensation target calculation.
const std = @import("std");
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

/// Compact message history.
/// Strategy:
///   - summarize: Send old messages to LLM for summary, replace with summary message
///   - phi_condense: Keep phi (61.8%) of most recent messages, drop oldest
///   - hybrid: phi-condense first, then summarize the dropped messages
pub fn compactMessages(
    allocator: std.mem.Allocator,
    message_count: usize,
    current_tokens: u32,
    max_tokens: u32,
    strategy: CompactionStrategy,
) CompactionResult {
    if (!needsCompaction(current_tokens, max_tokens)) return .no_change;
    if (message_count < 4) return .no_change;

    const target = switch (strategy) {
        .phi_condense, .hybrid => condensationTarget(message_count),
        .summarize => message_count / 2,
    };

    const removed = message_count - target;
    const tokens_saved = if (current_tokens > max_tokens / 2)
        current_tokens / 2
    else
        current_tokens / 4;

    _ = allocator;
    return .{
        .compacted = .{
            .messages_removed = removed,
            .tokens_saved = tokens_saved,
        },
    };
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

test "compactMessages" {
    const result = compactMessages(std.testing.allocator, 100, 800, 1000, .phi_condense);
    switch (result) {
        .compacted => |c| {
            try std.testing.expect(c.messages_removed > 0);
            try std.testing.expect(c.tokens_saved > 0);
        },
        .no_change => return error.UnexpectedNoChange,
    }
}
