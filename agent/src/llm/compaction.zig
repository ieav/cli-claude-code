/// Message compaction — compress conversation history when context exceeds phi threshold.
/// Real history truncation lives in repl.zig compactHistoryImpl (maybeCompact,
/// /compact); this module provides the φ threshold math it relies on.
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

