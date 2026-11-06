/// Token counting and budget estimation utilities.
const std = @import("std");

/// Char-class-aware token estimate. The old raw bytes/4 heuristic
/// underestimated CJK text by 2-3x: a Chinese char is 3 UTF-8 bytes but
/// costs ~1-2 real tokens in modern tokenizers (GPT-4o / Claude / Qwen
/// average ~1-1.5). Every budget in ziv (compaction threshold, memory
/// injection, context watermark) is built on this number, so err HIGH:
/// compaction firing slightly early is safe, firing late overflows the
/// gateway's context window. Weights: ASCII 4 chars/token, CJK & CJK
/// punctuation & fullwidth forms 1.5 tokens/char, other non-ASCII
/// (accented Latin etc.) 1 token/char.
pub fn estimateTokens(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var ascii: f64 = 0;
    var cjk: f64 = 0;
    var other: f64 = 0;
    const view = std.unicode.Utf8View.init(text) catch {
        // Invalid UTF-8: fall back to the old byte heuristic.
        return @intFromFloat(@ceil(@as(f64, @floatFromInt(text.len)) / 4.0));
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0x7F) {
            ascii += 1;
        } else if ((cp >= 0x2E80 and cp <= 0x9FFF) or // CJK radicals, kana, han
            (cp >= 0xAC00 and cp <= 0xD7AF) or // hangul syllables
            (cp >= 0xF900 and cp <= 0xFAFF) or // CJK compatibility ideographs
            (cp >= 0xFF00 and cp <= 0xFFEF) or // fullwidth/halfwidth forms
            (cp >= 0x3000 and cp <= 0x303F)) // CJK punctuation (subset of 2E80-9FFF kept explicit)
        {
            cjk += 1;
        } else {
            other += 1;
        }
    }
    return @intFromFloat(@ceil(ascii / 4.0 + cjk * 1.5 + other));
}

/// Token budget tracker.
pub const TokenBudget = struct {
    used: u32,
    max: u32,

    const Self = @This();

    pub fn init(max_tokens: u32) Self {
        return .{ .used = 0, .max = max_tokens };
    }

    pub fn remaining(self: *const Self) u32 {
        return if (self.max > self.used) self.max - self.used else 0;
    }

    pub fn usageRatio(self: *const Self) f64 {
        if (self.max == 0) return 1.0;
        return @as(f64, @floatFromInt(self.used)) / @as(f64, @floatFromInt(self.max));
    }

    pub fn consume(self: *Self, tokens: u32) void {
        self.used += tokens;
        if (self.used > self.max) self.used = self.max;
    }

    pub fn isExceeded(self: *const Self) bool {
        return self.used >= self.max;
    }

    /// Check if usage exceeds the phi threshold (61.8%).
    pub fn isPhiThreshold(self: *const Self) bool {
        return self.usageRatio() > 0.618;
    }
};

test "estimateTokens" {
    try std.testing.expectEqual(@as(u32, 1), estimateTokens("hi"));
    // ceil(16/4): len/4 heuristic, not word count
    try std.testing.expectEqual(@as(u32, 4), estimateTokens("hello world test"));
}

test "estimateTokens counts CJK as ~1.5 tokens per char, not 0.75" {
    // 6 han chars = 18 UTF-8 bytes → the old bytes/4 said 3; real cost ~6-12.
    try std.testing.expectEqual(@as(u32, 9), estimateTokens("你好世界测试"));
    // Mixed: "修复一下 bug" = 4 CJK (6.0) + 4 ASCII incl space (1.0) → 7.
    try std.testing.expectEqual(@as(u32, 7), estimateTokens("修复一下 bug"));
    // Invalid UTF-8 falls back to bytes/4.
    try std.testing.expectEqual(@as(u32, 1), estimateTokens(&.{ 0xFF, 0xFE, 0xFD, 0xFC }));
}

test "TokenBudget" {
    var budget = TokenBudget.init(1000);
    try std.testing.expect(!budget.isPhiThreshold());
    budget.consume(700);
    try std.testing.expect(budget.isPhiThreshold());
    try std.testing.expectEqual(@as(u32, 300), budget.remaining());
}
