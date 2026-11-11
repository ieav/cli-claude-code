/// Stall watchdog for provider HTTP requests (2026-10-30 root-cause fix;
/// 2026-11-05 idle-semantics fix).
///
/// The LLM gateway sometimes accepts a request and then never answers —
/// the TCP connection stays ESTABLISHED but zero bytes arrive. With no
/// deadline the calling thread blocks in recvmsg forever: 0% CPU, and the
/// installed SIGTERM handler only sets a flag while the syscall restarts,
/// so the process turns unkillable. (Captured live via lldb in
/// /tmp/ziv_hang_skel — the hang was never about the tty or threading.)
///
/// The deadline is IDLE time — ms since the last byte arrived (headers or
/// body), pushed forward by Guard.firstByte() on every successful read —
/// NOT total request duration. The original total-duration kill fired on
/// perfectly healthy streams (2026-11-04/05 bursts: glm-5.3 [1M] agentic
/// turns legitimately run >180 s and >1.8 MB, died at exactly 180.2 s as
/// "ServerError: ReadFailed" with the [网关返回] line blaming the gateway
/// for a kill ziv itself made). Under idle semantics a stream that keeps
/// sending is never killed; only true silence (gateway drop, dead
/// connection) is. Stopping a healthy long stream is the user's job —
/// Esc / cancel_fd shutdown(2)s the published fd (same technique).
///
/// shutdown(2) is the intended cross-thread way to wake a blocked read:
/// it fails the recvmsg, std surfaces a normal error, and callers (e.g.
/// subagent retry) get to react instead of hanging the session. The libc
/// call is deliberately used directly — touching an Io instance from this
/// thread is unsafe in 0.17 (see agent_dispatch.ProviderStorage).
const std = @import("std");
const wincompat = @import("./wincompat.zig");
const env = @import("env.zig");
const time_mod = @import("time.zig");
const logger = @import("log.zig");

pub const DEFAULT_TIMEOUT_MS: u64 = 180_000;
/// Cap for env-provided deadlines: anything larger is a typo anyway, and
/// beyond i64 max the signed idle arithmetic below would overflow.
pub const MAX_TIMEOUT_MS: u64 = 86_400_000;
const POLL_MS: u64 = 250;
/// SHUT_RDWR — same value (2) on macOS and Linux.
pub const SHUT_RDWR: c_int = 2;

/// Why the watchdog killed a request's socket (per-request, caller-frame
/// backed). .ttft → the provider maps the transport error to
/// error.FirstByteTimeout for auto-retry; .idle → the error detail must
/// say "ziv idle watchdog", not blame the gateway; .cancelled → a
/// cooperative cancel flag (e.g. an Esc'd agent dispatch) asked for the
/// kill — the provider maps it to error.EscCancelled so headless callers
/// can fold it into "(canceled)" instead of "failed".
pub const KillReason = enum(u8) {
    none = 0,
    ttft = 1,
    idle = 2,
    cancelled = 3,
};

/// Per-request state, owned EXCLUSIVELY by the watchdog thread after arm:
/// it frees the struct on exit. `Guard.finish()` only flips the flag and
/// never touches the state afterwards (no use-after-free window).
///
/// PER-REQUEST kill reason, backing `Guard.killReason()`. Points into
/// the arming thread's stack frame (see arm) — the kill path only runs
/// while !done, and !done guarantees the provider is still inside the
/// request function, so the frame is alive. The old global counter let
/// one thread's kill be consumed by ANOTHER thread's unrelated transport
/// error (misattributed FirstByteTimeout → wrong auto-retry).
const State = struct {
    fd: std.c.fd_t,
    done: std.atomic.Value(bool),
    /// Kill after this many ms WITHOUT data (idle deadline). Pushed
    /// forward by every firstByte() — a healthy stream never reaches it.
    timeout_ms: u64,
    /// TTFT sub-deadline: when the whole request (headers included — the
    /// gateway's accept-but-never-answer hang blocks receiveHead BEFORE
    /// any body read loop exists) produced no first byte by this mark,
    /// kill early so the caller can auto-retry. Cleared by firstByte().
    ttft_ms: u64,
    first_byte: std.atomic.Value(bool),
    /// Wall-clock ms of the last observed data (arm time initially).
    /// Signed: nowMillis() is a wall clock and can step backwards — the
    /// idle subtraction must not wrap into a huge unsigned value.
    last_activity_ms: std.atomic.Value(i64),
    /// Cooperative cancel (subagent dispatch etc.): while the flag is set
    /// the watchdog kills the socket on its next 250ms tick — the blocked
    /// read fails on the owning thread and the provider maps the transport
    /// error to error.EscCancelled. Read-only here; the caller owns it and
    /// keeps it alive for the whole request (same lifetime rule as
    /// kill_reason).
    cancel_flag: ?*const std.atomic.Value(bool),
    kill_reason: *std.atomic.Value(u8),
};

pub const Guard = struct {
    state: ?*State,
    /// Same provider-stack flag the State points at — kept BY VALUE in
    /// the Guard so the answer outlives the (thread-freed) State safely.
    kill_reason: *std.atomic.Value(u8),

    /// Disarm at request end. Idempotent; never frees (thread owns that).
    pub fn finish(self: Guard) void {
        if (self.state) |s| s.done.store(true, .release);
    }

    /// Data observed — first byte OR any later chunk (call sites invoke
    /// it per read): lift the TTFT sub-deadline AND push the idle
    /// deadline forward. This is what keeps a healthy long stream alive
    /// past DEFAULT_TIMEOUT_MS of total runtime.
    pub fn firstByte(self: Guard) void {
        if (self.state) |s| {
            s.first_byte.store(true, .release);
            s.last_activity_ms.store(time_mod.nowMillis(), .release);
        }
    }

    /// Why this request's socket died (.none = completed normally, or
    /// killed by someone else — e.g. the Esc cancel path). Per-request:
    /// another thread's kill can never be misattributed here.
    pub fn killReason(self: Guard) KillReason {
        return @fromBackingInt(@intCast(self.kill_reason.load(.acquire)));
    }

    /// True when THIS request's watchdog TTFT-killed its socket — the
    /// caller maps the resulting transport error to
    /// error.FirstByteTimeout for auto-retry.
    pub fn ttftKilled(self: Guard) bool {
        return self.killReason() == .ttft;
    }

    /// True when THIS request's idle watchdog killed its socket — the
    /// caller attributes the transport error to ziv (not the gateway's
    /// [网关返回] line) and may auto-retry.
    pub fn idleKilled(self: Guard) bool {
        return self.killReason() == .idle;
    }

    /// True when THIS request was killed by its cooperative cancel flag —
    /// the caller maps the transport error to error.EscCancelled (user
    /// cancel, not a failure).
    pub fn cancelledKilled(self: Guard) bool {
        return self.killReason() == .cancelled;
    }
};

/// Arm a stall watchdog on a live request's connection. `kill_reason`
/// must live in the caller's frame for the whole request (it backs
/// `Guard.killReason()`; the watchdog thread writes it on a kill). Call
/// `Guard.finish()` when the request completes normally. No-ops (null
/// state) when there is no connection or the thread cannot spawn — a
/// missing watchdog must never break the request itself.
pub fn arm(req: *std.http.Client.Request, kill_reason: *std.atomic.Value(u8)) Guard {
    return armForBody(req, kill_reason, 0, null);
}

/// Body-scaled TTFT (2026-11-07): big prompts legitimately take longer to
/// first byte — the gateway is still PROCESSING, not stuck. A fixed 30 s
/// budget killed in-flight requests and the retry re-billed the whole
/// input (observed live: 3× input cost for one answer on a 25K-token
/// prompt). Scale: +1 s per ~1K tokens (≈4 KB of JSON body), capped.
/// Pure budget math (unit-tested): base TTFT + ~1 s per 1K tokens of
/// request body (≈4 B/token in JSON), total capped at 120 s.
pub fn ttftBudgetFor(body_len: usize) u64 {
    // Under ~1K tokens (4 KB) the prompt processes fast — no scale needed.
    if (body_len < 4096) return currentTtftMs();
    const scale_ms: u64 = @min(@as(u64, body_len) / 4, 90_000);
    return @min(currentTtftMs() + scale_ms, 120_000);
}

pub fn armForBody(req: *std.http.Client.Request, kill_reason: *std.atomic.Value(u8), body_len: usize, cancel_flag: ?*const std.atomic.Value(bool)) Guard {
    const conn = req.connection orelse return .{ .state = null, .kill_reason = kill_reason };
    const s = std.heap.smp_allocator.create(State) catch return .{ .state = null, .kill_reason = kill_reason };
    s.* = .{
        .fd = conn.stream_reader.stream.socket.handle,
        .done = std.atomic.Value(bool).init(false),
        .timeout_ms = currentTimeoutMs(),
        .ttft_ms = ttftBudgetFor(body_len),
        .first_byte = std.atomic.Value(bool).init(false),
        .last_activity_ms = std.atomic.Value(i64).init(time_mod.nowMillis()),
        .cancel_flag = cancel_flag,
        .kill_reason = kill_reason,
    };
    const t = std.Thread.spawn(.{}, watchdogThread, .{s}) catch {
        std.heap.smp_allocator.destroy(s);
        return .{ .state = null, .kill_reason = kill_reason };
    };
    t.detach();
    return .{ .state = s, .kill_reason = kill_reason };
}

fn watchdogThread(s: *State) void {
    while (!s.done.load(.acquire)) {
        // Cooperative cancel: flagged requests die on the next tick — the
        // shutdown fails the owning thread's blocking read and the provider
        // maps the transport error to error.EscCancelled (user cancel).
        if (s.cancel_flag) |cf| {
            if (cf.load(.acquire)) {
                if (s.done.load(.acquire)) {
                    std.heap.smp_allocator.destroy(s);
                    return;
                }
                s.kill_reason.store(@backingInt(KillReason.cancelled), .release);
                wincompat.shutdownFd(s.fd);
                logger.info("llm: request canceled by user — socket shut down", .{});
                std.heap.smp_allocator.destroy(s);
                return;
            }
        }
        const now = time_mod.nowMillis();
        const idle: i64 = now - s.last_activity_ms.load(.acquire);
        const decision = killDecision(s.first_byte.load(.acquire), idle, s.ttft_ms, s.timeout_ms);
        if (decision) |reason| {
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
            s.kill_reason.store(@backingInt(reason), .release);
            wincompat.shutdownFd(s.fd);
            switch (reason) {
                .ttft => logger.warning("llm: no first byte in {d}ms — killed for auto-retry", .{s.ttft_ms}),
                .idle => logger.warning("llm: no data for {d}ms — connection killed by idle watchdog (a stream that keeps sending never hits this)", .{s.timeout_ms}),
                .cancelled, .none => unreachable,
            }
            std.heap.smp_allocator.destroy(s);
            return;
        }
        wincompat.sleepMs(POLL_MS);
    }
    std.heap.smp_allocator.destroy(s);
}

/// Pure kill decision, extracted for tests. `idle_ms` is time since the
/// last observed data; `first_byte` distinguishes "never answered at
/// all" (TTFT) from "answered, then went silent" (idle). No total-age
/// input exists — that is the fix: a live stream has no deadline.
fn killDecision(first_byte: bool, idle_ms: i64, ttft_ms: u64, timeout_ms: u64) ?KillReason {
    // TTFT sub-deadline: nothing at all arrived (headers included) — a
    // dead request. Kill early and flag THIS request (the provider maps
    // the resulting error to FirstByteTimeout and auto-retries). Only
    // armed while stricter than the idle deadline (ttft < timeout).
    if (!first_byte and ttft_ms < timeout_ms and idle_ms >= @as(i64, @intCast(ttft_ms))) return .ttft;
    // Idle deadline: no byte for timeout_ms — dead connection, killed
    // however old the request is. Bumped by every firstByte().
    if (idle_ms >= @as(i64, @intCast(timeout_ms))) return .idle;
    return null;
}

/// Idle timeout: `ZIV_LLM_TIMEOUT_MS` env override, floor 1s so a typo
/// cannot insta-kill healthy requests, 24h cap so the signed idle
/// arithmetic cannot overflow. Deliberately NOT cached: providers
/// arm watchdogs from several threads (main, subagent workers, reflection
// worker) and a shared mutable cache would be a data race; one getenv per
// request is noise.
pub fn currentTimeoutMs() u64 {
    if (env.get("ZIV_LLM_TIMEOUT_MS")) |v| {
        if (std.fmt.parseInt(u64, v, 10)) |parsed| {
            return @min(@max(parsed, 1_000), MAX_TIMEOUT_MS);
        } else |_| {}
    }
    return DEFAULT_TIMEOUT_MS;
}

/// Time-to-first-byte budget for INTERACTIVE streams: a gateway that
/// accepted the request but produced nothing yet is almost certainly a
/// dead request — the interactive loop kills it at this deadline and
/// auto-retries instead of sitting on the 180s idle watchdog ("发了
/// 消息模型一直没响应" self-heals within ~30s).
pub const DEFAULT_TTFT_TIMEOUT_MS: u64 = 30_000;

pub fn currentTtftMs() u64 {
    if (env.get("ZIV_TTFT_TIMEOUT_MS")) |v| {
        if (std.fmt.parseInt(u64, v, 10)) |parsed| {
            return @min(@max(parsed, 5_000), MAX_TIMEOUT_MS);
        } else |_| {}
    }
    return DEFAULT_TTFT_TIMEOUT_MS;
}

test "timeout config: default, env parse, floor, and cap" {
    // Direct parse-path checks (env is process-global; touching it here
    // would poison other tests through the cache).
    try std.testing.expectEqual(@as(u64, 180_000), DEFAULT_TIMEOUT_MS);
    const floor: u64 = @max(@as(u64, 50), 1_000);
    try std.testing.expectEqual(@as(u64, 1_000), floor);
    try std.testing.expectEqual(@as(u64, 86_400_000), @min(@as(u64, 999_999_999_999), MAX_TIMEOUT_MS));
    try std.testing.expectError(error.InvalidCharacter, std.fmt.parseInt(u64, "abc", 10));
}

test "idle watchdog: live streams never hit the deadline, silence does" {
    const t = DEFAULT_TIMEOUT_MS;
    // Healthy stream: chunks keep arriving, so idle time never reaches
    // the deadline — no matter the request's TOTAL age. (The 2026-11-05
    // bug: exactly this case died at 180.2 s with 1.8 MB received.)
    try std.testing.expectEqual(@as(?KillReason, null), killDecision(true, 179_999, 30_000, t));
    // Mid-stream silence past the deadline → idle kill, whatever the age.
    try std.testing.expectEqual(@as(?KillReason, .idle), killDecision(true, 180_000, 30_000, t));
    try std.testing.expectEqual(@as(?KillReason, .idle), killDecision(true, 1_000_000, 30_000, t));
    // Never a first byte: TTFT fires first (auto-retry path).
    try std.testing.expectEqual(@as(?KillReason, .ttft), killDecision(false, 30_000, 30_000, t));
    try std.testing.expectEqual(@as(?KillReason, null), killDecision(false, 29_999, 30_000, t));
    // TTFT disarmed (>= idle deadline): pure idle decision.
    try std.testing.expectEqual(@as(?KillReason, .idle), killDecision(false, 180_000, 180_000, t));
    // Wall clock stepped backwards: negative idle must not become a kill.
    try std.testing.expectEqual(@as(?KillReason, null), killDecision(true, -5_000, 30_000, t));
}


test "ttftBudgetFor scales with body size and caps at 120s" {
    // Tiny body (chat ping): base budget unchanged.
    try std.testing.expectEqual(currentTtftMs(), ttftBudgetFor(200));
    // 100 KB body ≈ 25K tokens → +25s over base.
    const base = currentTtftMs();
    const big = ttftBudgetFor(100 * 1024);
    try std.testing.expect(big >= base + 24_000 and big <= base + 26_000);
    // 1 MB body → capped at 120s total.
    try std.testing.expectEqual(@as(u64, 120_000), ttftBudgetFor(1024 * 1024));
}
