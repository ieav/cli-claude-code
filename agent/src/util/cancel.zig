/// Cancel token — cooperative cancellation via atomic bool.
/// Inspired by TS AbortController / AbortSignal pattern.
const std = @import("std");

/// Session-scoped cancel slot for the CURRENTLY-RUNNING tool batch.
/// The REPL UI loop arms it when the user presses Esc/Ctrl-C while tools
/// execute; cooperative checkpoints poll it:
///   - bash.zig's watchdog kills the child's whole process group (this is
///     the only way to unbind an unlimited `timeout: 0` command), and
///   - orchestration.executeToolCall short-circuits every not-yet-started
///     call to "cancelled (not run)" so all tool_use ids still get a
///     tool_result (history stays API-valid) and the batch finishes fast.
/// The REPL clears the flag before arming each batch (a stale `true` would
/// silently no-op every later tool) and after the batch's results land.
/// One batch runs per process at a time (turns are serial), so a single
/// global is correct; a nested agent-tool turn shares it — cancelling the
/// outer batch cancels the inner tools too, which is the desired semantic.
pub var tool_batch_cancel = std.atomic.Value(bool).init(false);

/// True when the current tool batch was cancelled by the user.
pub fn toolBatchCancelled() bool {
    return tool_batch_cancel.load(.acquire);
}

/// Arm/clear the slot — call right before a batch starts executing.
pub fn toolBatchReset() void {
    tool_batch_cancel.store(false, .release);
}

/// Fire the slot — Esc/Ctrl-C during tool execution.
pub fn toolBatchCancel() void {
    tool_batch_cancel.store(true, .release);
}

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
