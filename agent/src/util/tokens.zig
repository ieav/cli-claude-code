/// Token counting and budget estimation utilities.
const std = @import("std");

/// Rough estimate of tokens for a text string.
/// Uses ~4 chars per token heuristic (GPT-family standard).
pub fn estimateTokens(text: []const u8) u32 {
    if (text.len == 0) return 0;
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(text.len)) / 4.0));
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

test "TokenBudget" {
    var budget = TokenBudget.init(1000);
    try std.testing.expect(!budget.isPhiThreshold());
    budget.consume(700);
    try std.testing.expect(budget.isPhiThreshold());
    try std.testing.expectEqual(@as(u32, 300), budget.remaining());
}
