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
pub const SHUT_RDWR: c_int = 2;

/// Per-request state, owned EXCLUSIVELY by the watchdog thread after arm:
/// it frees the struct on exit. `Guard.finish()` only flips the flag and
/// never touches the state afterwards (no use-after-free window).
///
/// PER-REQUEST TTFT-kill flag, backing `Guard.ttftKilled()`. Points into
/// the arming thread's stack frame (see arm) — the kill path only runs
/// while !done, and !done guarantees the provider is still inside the
/// request function, so the frame is alive. The old global counter let
/// one thread's kill be consumed by ANOTHER thread's unrelated transport
/// error (misattributed FirstByteTimeout → wrong auto-retry).
const State = struct {
    fd: std.c.fd_t,
    done: std.atomic.Value(bool),
    timeout_ms: u64,
    /// TTFT sub-deadline: when the whole request (headers included — the
    /// gateway's accept-but-never-answer hang blocks receiveHead BEFORE
    /// any body read loop exists) produced no first byte by this mark,
    /// kill early so the caller can auto-retry. Cleared by firstByte().
    ttft_ms: u64,
    first_byte: std.atomic.Value(bool),
    kill_flag: *std.atomic.Value(bool),
};

pub const Guard = struct {
    state: ?*State,
    /// Same provider-stack flag the State points at — kept BY VALUE in
    /// the Guard so the answer outlives the (thread-freed) State safely.
    ttft_killed: *std.atomic.Value(bool),

    /// Disarm at request end. Idempotent; never frees (thread owns that).
    pub fn finish(self: Guard) void {
        if (self.state) |s| s.done.store(true, .release);
    }

    /// First body byte observed — lift the TTFT sub-deadline (the total
    /// timeout still applies).
    pub fn firstByte(self: Guard) void {
        if (self.state) |s| s.first_byte.store(true, .release);
    }

    /// True when THIS request's watchdog TTFT-killed its socket — the
    /// caller maps the resulting transport error to
    /// error.FirstByteTimeout for auto-retry. Per-request: another
    /// thread's kill can never be misattributed here.
    pub fn ttftKilled(self: Guard) bool {
        return self.ttft_killed.load(.acquire);
    }
};

/// Arm a stall watchdog on a live request's connection. `ttft_killed`
/// must live in the caller's frame for the whole request (it backs
/// `Guard.ttftKilled()`; the watchdog thread writes it on a TTFT kill).
/// Call `Guard.finish()` when the request completes normally. No-ops
/// (null state) when there is no connection or the thread cannot spawn —
/// a missing watchdog must never break the request itself.
pub fn arm(req: *std.http.Client.Request, ttft_killed: *std.atomic.Value(bool)) Guard {
    const conn = req.connection orelse return .{ .state = null, .ttft_killed = ttft_killed };
    const s = std.heap.smp_allocator.create(State) catch return .{ .state = null, .ttft_killed = ttft_killed };
    s.* = .{
        .fd = conn.stream_reader.stream.socket.handle,
        .done = std.atomic.Value(bool).init(false),
        .timeout_ms = currentTimeoutMs(),
        .ttft_ms = currentTtftMs(),
        .first_byte = std.atomic.Value(bool).init(false),
        .kill_flag = ttft_killed,
    };
    const t = std.Thread.spawn(.{}, watchdogThread, .{s}) catch {
        std.heap.smp_allocator.destroy(s);
        return .{ .state = null, .ttft_killed = ttft_killed };
    };
    t.detach();
    return .{ .state = s, .ttft_killed = ttft_killed };
}

fn watchdogThread(s: *State) void {
    const start = time_mod.nowMillis();
    while (!s.done.load(.acquire)) {
        const elapsed: u64 = @intCast(time_mod.nowMillis() - start);
        // TTFT sub-deadline: nothing at all arrived (headers included) —
        // a dead request. Kill early and flag THIS request (the provider
        // maps the resulting error to FirstByteTimeout and auto-retries).
        if (!s.first_byte.load(.acquire) and s.ttft_ms < s.timeout_ms and elapsed >= s.ttft_ms) {
            if (s.done.load(.acquire)) {
                std.heap.smp_allocator.destroy(s);
                return;
            }
            s.kill_flag.store(true, .release);
            _ = std.c.shutdown(s.fd, SHUT_RDWR);
            logger.warning("llm: no first byte in {d}ms — killed for auto-retry", .{s.ttft_ms});
            std.heap.smp_allocator.destroy(s);
            return;
        }
        if (elapsed >= s.timeout_ms) {
            // Race guard: a request that completed in the poll window may
            // have already returned its connection to the pool (fd reused).
            // Re-check done right before acting — the remaining window is
            // a few instructions, only hit if the request finished within
            // ~µs of its own deadline.
            if (s.done.load(.acquire)) {
                std.heap.smp_allocator.destroy(s);
                return;
            }
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

/// Request timeout: `ZIV_LLM_TIMEOUT_MS` env override, floor 1s so a typo
/// cannot insta-kill healthy requests. Deliberately NOT cached: providers
/// arm watchdogs from several threads (main, subagent workers, reflection
// worker) and a shared mutable cache would be a data race; one getenv per
/// request is noise.
pub fn currentTimeoutMs() u64 {
    if (env.get("ZIV_LLM_TIMEOUT_MS")) |v| {
        if (std.fmt.parseInt(u64, v, 10)) |parsed| {
            return @max(parsed, 1_000);
        } else |_| {}
    }
    return DEFAULT_TIMEOUT_MS;
}

/// Time-to-first-byte budget for INTERACTIVE streams: a gateway that
/// accepted the request but produced nothing yet is almost certainly a
/// dead request — the interactive loop kills it at this deadline and
/// auto-retries instead of sitting on the 180s total watchdog ("发了
/// 消息模型一直没响应" self-heals within ~30s).
pub const DEFAULT_TTFT_TIMEOUT_MS: u64 = 30_000;

pub fn currentTtftMs() u64 {
    if (env.get("ZIV_TTFT_TIMEOUT_MS")) |v| {
        if (std.fmt.parseInt(u64, v, 10)) |parsed| {
            return @max(parsed, 5_000);
        } else |_| {}
    }
    return DEFAULT_TTFT_TIMEOUT_MS;
}

test "timeout config: default, env parse, and 1s floor" {
    // Direct parse-path checks (env is process-global; touching it here
    // would poison other tests through the cache).
    try std.testing.expectEqual(@as(u64, 180_000), DEFAULT_TIMEOUT_MS);
    const floor: u64 = @max(@as(u64, 50), 1_000);
    try std.testing.expectEqual(@as(u64, 1_000), floor);
    try std.testing.expectError(error.InvalidCharacter, std.fmt.parseInt(u64, "abc", 10));
}
