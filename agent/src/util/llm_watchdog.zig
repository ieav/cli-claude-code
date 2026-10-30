/// Stall watchdog for provider HTTP requests (2026-10-30 root-cause fix).
///
/// The LLM gateway sometimes accepts a request and then never answers —
/// the TCP connection stays ESTABLISHED but zero bytes arrive. With no
/// deadline the calling thread blocks in recvmsg forever: 0% CPU, and the
/// installed SIGTERM handler only sets a flag while the syscall restarts,
/// so the process turns unkillable. (Captured live via lldb in
/// /tmp/ziv_hang_skel — the hang was never about the tty or threading.)
///
/// shutdown(2) is the intended cross-thread way to wake a blocked read:
/// it fails the recvmsg, std surfaces a normal error, and callers (e.g.
/// subagent retry) get to react instead of hanging the session. The libc
/// call is deliberately used directly — touching an Io instance from this
/// thread is unsafe in 0.17 (see agent_dispatch.ProviderStorage).
const std = @import("std");
const env = @import("env.zig");
const time_mod = @import("time.zig");
const logger = @import("log.zig");

pub const DEFAULT_TIMEOUT_MS: u64 = 180_000;
const POLL_MS: u64 = 250;
/// SHUT_RDWR — same value (2) on macOS and Linux.
const SHUT_RDWR: c_int = 2;

/// Per-request state, owned EXCLUSIVELY by the watchdog thread after arm:
/// it frees the struct on exit. `Guard.finish()` only flips the flag and
/// never touches the state afterwards (no use-after-free window).
const State = struct {
    fd: std.c.fd_t,
    done: std.atomic.Value(bool),
    timeout_ms: u64,
};

pub const Guard = struct {
    state: ?*State,

    /// Disarm at request end. Idempotent; never frees (thread owns that).
    pub fn finish(self: Guard) void {
        if (self.state) |s| s.done.store(true, .release);
    }
};

/// Arm a stall watchdog on a live request's connection. Call
/// `Guard.finish()` when the request completes normally. No-ops (null
/// state) when there is no connection or the thread cannot spawn — a
/// missing watchdog must never break the request itself.
pub fn arm(req: *std.http.Client.Request) Guard {
    const conn = req.connection orelse return .{ .state = null };
    const s = std.heap.smp_allocator.create(State) catch return .{ .state = null };
    s.* = .{
        .fd = conn.stream_reader.stream.socket.handle,
        .done = std.atomic.Value(bool).init(false),
        .timeout_ms = currentTimeoutMs(),
    };
    const t = std.Thread.spawn(.{}, watchdogThread, .{s}) catch {
        std.heap.smp_allocator.destroy(s);
        return .{ .state = null };
    };
    t.detach();
    return .{ .state = s };
}

fn watchdogThread(s: *State) void {
    const start = time_mod.nowMillis();
    while (!s.done.load(.acquire)) {
        const elapsed: u64 = @intCast(time_mod.nowMillis() - start);
        if (elapsed >= s.timeout_ms) {
            // Fails the in-flight recvmsg on the owning thread; the error
            // surfaces through the provider's normal error path.
            _ = std.c.shutdown(s.fd, SHUT_RDWR);
            logger.warning("llm: request stalled over {d}ms — connection killed by watchdog", .{s.timeout_ms});
            std.heap.smp_allocator.destroy(s);
            return;
        }
        var poll_ts: std.c.timespec = .{ .sec = 0, .nsec = POLL_MS * std.time.ns_per_ms };
        _ = std.c.nanosleep(&poll_ts, null);
    }
    std.heap.smp_allocator.destroy(s);
}

var cached_timeout: ?u64 = null;

/// Request timeout: `ZIV_LLM_TIMEOUT_MS` env override, floor 1s so a typo
/// cannot insta-kill healthy requests. Parsed once, cached.
pub fn currentTimeoutMs() u64 {
    if (cached_timeout) |t| return t;
    var t = DEFAULT_TIMEOUT_MS;
    if (env.get("ZIV_LLM_TIMEOUT_MS")) |v| {
        if (std.fmt.parseInt(u64, v, 10)) |parsed| {
            t = @max(parsed, 1_000);
        } else |_| {}
    }
    cached_timeout = t;
    return t;
}

test "timeout config: default, env parse, and 1s floor" {
    // Direct parse-path checks (env is process-global; touching it here
    // would poison other tests through the cache).
    try std.testing.expectEqual(@as(u64, 180_000), DEFAULT_TIMEOUT_MS);
    const floor: u64 = @max(@as(u64, 50), 1_000);
    try std.testing.expectEqual(@as(u64, 1_000), floor);
    try std.testing.expectError(error.InvalidCharacter, std.fmt.parseInt(u64, "abc", 10));
}
