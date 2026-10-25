/// Denial tracker — track consecutive permission denials to prevent loops.
/// Falls back to prompting mode after too many consecutive denials.
const std = @import("std");

pub const DenialTracker = struct {
    consecutive_denials: u32,
    total_denials: u32,
    max_consecutive: u32, // threshold to fall back to prompt mode

    const Self = @This();

    pub fn init(max_consecutive: u32) Self {
        return .{
            .consecutive_denials = 0,
            .total_denials = 0,
            .max_consecutive = max_consecutive,
        };
    }

    /// Record a denial. Returns true if we should fall back to prompting.
    pub fn recordDenial(self: *Self) bool {
        self.consecutive_denials += 1;
        self.total_denials += 1;
        return self.consecutive_denials >= self.max_consecutive;
    }

    /// Record an approval — resets consecutive counter.
    pub fn recordApproval(self: *Self) void {
        self.consecutive_denials = 0;
    }

    /// Check if we're in denial loop territory.
    pub fn isLooping(self: *const Self) bool {
        return self.consecutive_denials >= self.max_consecutive;
    }

    /// Reset all counters.
    pub fn reset(self: *Self) void {
        self.consecutive_denials = 0;
        self.total_denials = 0;
    }
};

test "DenialTracker" {
    var tracker = DenialTracker.init(3);
    try std.testing.expect(!tracker.isLooping());

    _ = tracker.recordDenial();
    _ = tracker.recordDenial();
    try std.testing.expect(!tracker.isLooping());

    const should_prompt = tracker.recordDenial();
    try std.testing.expect(should_prompt);
    try std.testing.expect(tracker.isLooping());

    tracker.recordApproval();
    try std.testing.expect(!tracker.isLooping());
    try std.testing.expectEqual(@as(u32, 3), tracker.total_denials);
}
