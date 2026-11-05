/// Cross-thread turn timing state (R2 收口, 2026-11-06).
///
/// Three loose file-level globals (live_turn_t0 / live_llm_rounds /
/// last_trace_path_buf+len) became ONE namespaced object with atomics:
/// the StreamJob ticker thread and the turn loop now read/write through
/// the same API instead of reaching into raw globals. Ownership stays
/// simple — every field has a single writer (the turn loop, on the main
/// thread); the ticker only reads, so release/acquire pairs suffice.
const std = @import("std");

var t0 = std.atomic.Value(i64).init(0);
var rounds = std.atomic.Value(u32).init(0);
var path_buf: [160]u8 = undefined;
var path_len = std.atomic.Value(usize).init(0);

/// Turn start (writer: turn loop).
pub fn turnStart(now_ms: i64) void {
    t0.store(now_ms, .release);
    rounds.store(0, .release);
}

/// A generation completed (writer: turn loop) — mirrors turn_llm_calls.
pub fn roundDone(completed_rounds: u32) void {
    rounds.store(completed_rounds, .release);
}

/// Elapsed ms since turn start; 0 when no turn is live.
pub fn elapsedMs(now_ms: i64) i64 {
    const v = t0.load(.acquire);
    return if (v != 0) now_ms - v else 0;
}

/// Completed rounds so far (a live generation displays roundsDone()+1).
pub fn roundsDone() u32 {
    return rounds.load(.acquire);
}

/// Path of the newest persisted trace. Bytes are written BEFORE the len
/// publish, so a reader that acquires the len sees consistent bytes.
pub fn setTracePath(p: []const u8) void {
    const n = @min(p.len, path_buf.len);
    @memcpy(path_buf[0..n], p[0..n]);
    path_len.store(n, .release);
}

/// Borrowed slice; empty until the first trace write of the session.
pub fn tracePath() []const u8 {
    return path_buf[0..path_len.load(.acquire)];
}
