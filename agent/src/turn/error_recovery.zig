//! Error recovery — P4's unified auto-fix ladder + the interactive choice
//! menu. The auto ladder runs BEFORE anything user-facing (429/timeout →
//! exponential backoff retry, capped per turn); when the ladder is spent
//! (or the error has no auto fix), the classified report prints and the
//! selector offers [1]重试 [2]压缩后重试 [3]换模型 [4]忽略 — the design
//! §五 "user chooses how to proceed" that previously only displayed
//! numbered suggestions.

const std = @import("std");
const menu = @import("../util/menu.zig");

pub const MAX_AUTO_RETRIES: u8 = 2;

pub const RecoveryChoice = enum {
    retry,
    compact_retry,
    switch_model,
    ignore,
};

pub const Backoff = struct {
    ms: u32,
    /// Human label for the retry notice (e.g. "429 限流").
    reason: []const u8,
};

/// Pure policy: which transient errors get an automatic backoff retry, and
/// how long to wait. `retries_used` counts THIS turn's auto retries so far
/// (exponential: 1s, 2s). Returns null when auto-fix is off, the budget is
/// spent, or the error is not transient (selector territory).
pub fn backoffPlan(err: anyerror, auto_fix_on: bool, retries_used: u8) ?Backoff {
    if (!auto_fix_on) return null;
    if (retries_used >= MAX_AUTO_RETRIES) return null;
    const reason: []const u8 = switch (err) {
        error.RateLimit => "429 限流",
        error.NetworkTimeout => "网络超时",
        error.ConnectionRefused => "连接被拒",
        error.ConnectionResetByPeer => "连接被重置",
        else => return null,
    };
    const ms: u32 = if (retries_used == 0) 1000 else 2000;
    return .{ .ms = ms, .reason = reason };
}

/// Errors where the selector makes no sense: the user cancelled on
/// purpose, or nothing can be retried (nothing sent).
pub fn selectorEligible(err: anyerror) bool {
    return switch (err) {
        error.EscCancelled, error.MissingApiKey, error.FirstByteTimeout => false,
        else => true,
    };
}

/// Arrow-key selector over the four recovery moves. Esc/q → null (treated
/// as ignore by the caller). Single-key reads — safe under the session-raw
/// terminal (same contract as /resume's picker).
pub fn offerMenu(w: *std.Io.Writer, r: *std.Io.Reader, file_writer: *std.Io.File.Writer) ?RecoveryChoice {
    const items = [_][]const u8{
        "重试本回合",
        "压缩历史后重试（φ 截断 + 工具结果瘦身）",
        "换模型（选择器）",
        "忽略 — 结束本回合，输入区预填「继续」",
    };
    const picked = (menu.select(w, r, file_writer, "如何处理这个错误？", &items, 0) catch null) orelse return null;
    return switch (picked) {
        0 => .retry,
        1 => .compact_retry,
        2 => .switch_model,
        else => .ignore,
    };
}

// ── tests ────────────────────────────────────────────────────────────

test "backoffPlan: transient errors back off exponentially, others don't" {
    // Auto-fix off → never.
    try std.testing.expect(backoffPlan(error.RateLimit, false, 0) == null);
    // Transient ladder: 1s then 2s, then budget spent.
    const b1 = backoffPlan(error.RateLimit, true, 0).?;
    try std.testing.expectEqual(@as(u32, 1000), b1.ms);
    const b2 = backoffPlan(error.NetworkTimeout, true, 1).?;
    try std.testing.expectEqual(@as(u32, 2000), b2.ms);
    try std.testing.expect(backoffPlan(error.RateLimit, true, 2) == null);
    // Non-transient errors go straight to the selector.
    try std.testing.expect(backoffPlan(error.ContextOverflow, true, 0) == null);
    try std.testing.expect(backoffPlan(error.EscCancelled, true, 0) == null);
    // Connection-class errors count as transient.
    try std.testing.expect(backoffPlan(error.ConnectionRefused, true, 0) != null);
}

test "selectorEligible excludes deliberate cancels and config problems" {
    try std.testing.expect(!selectorEligible(error.EscCancelled));
    try std.testing.expect(!selectorEligible(error.MissingApiKey));
    try std.testing.expect(selectorEligible(error.RateLimit));
    try std.testing.expect(selectorEligible(error.NetworkTimeout));
}
