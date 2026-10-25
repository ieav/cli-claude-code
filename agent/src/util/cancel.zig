/// Cancel token — cooperative cancellation via atomic bool.
/// Inspired by TS AbortController / AbortSignal pattern.
const std = @import("std");

pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool),

    const Self = @This();

    pub fn init() Self {
        return .{ .cancelled = std.atomic.Value(bool).init(false) };
    }

    pub fn cancel(self: *Self) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const Self) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn reset(self: *Self) void {
        self.cancelled.store(false, .release);
    }
};

/// Child token — cancelled when parent is cancelled OR when child is explicitly cancelled.
pub const ChildCancelToken = struct {
    parent: *const CancelToken,
    own: CancelToken,

    const Self = @This();

    pub fn init(parent: *const CancelToken) Self {
        return .{
            .parent = parent,
            .own = CancelToken.init(),
        };
    }

    pub fn cancel(self: *Self) void {
        self.own.cancel();
    }

    pub fn isCancelled(self: *const Self) bool {
        return self.parent.isCancelled() or self.own.isCancelled();
    }
};

/// Combined token — cancelled when ANY of the source tokens is cancelled.
pub const CombinedCancelToken = struct {
    tokens: []const *const CancelToken,

    const Self = @This();

    pub fn init(tokens: []const *const CancelToken) Self {
        return .{ .tokens = tokens };
    }

    pub fn isCancelled(self: *const Self) bool {
        for (self.tokens) |token| {
            if (token.isCancelled()) return true;
        }
        return false;
    }
};

test "CancelToken basic" {
    var token = CancelToken.init();
    try std.testing.expect(!token.isCancelled());
    token.cancel();
    try std.testing.expect(token.isCancelled());
    token.reset();
    try std.testing.expect(!token.isCancelled());
}

test "ChildCancelToken" {
    var parent = CancelToken.init();
    var child = ChildCancelToken.init(&parent);
    try std.testing.expect(!child.isCancelled());
    parent.cancel();
    try std.testing.expect(child.isCancelled());
}

test "CombinedCancelToken" {
    var t1 = CancelToken.init();
    var t2 = CancelToken.init();
    const refs = [_]*const CancelToken{ &t1, &t2 };
    var combined = CombinedCancelToken.init(&refs);
    try std.testing.expect(!combined.isCancelled());
    t2.cancel();
    try std.testing.expect(combined.isCancelled());
}
