/// Interruptible stream wait (2026-11-01 fix for the dead-input hang).
///
/// The REPL's Esc/Ctrl-C probe runs only when a stream EVENT fires
/// (streamCb → escProbe). A gateway that accepts a request and then never
/// answers produces ZERO events, so for the whole stall the terminal was
/// dead: no prompt, Esc/Ctrl-C swallowed (raw mode keeps ISIG off), and
/// the only recovery was the stall watchdog — 180s by default. Users
/// quite reasonably read that as "输入处不见了，无法输入".
///
/// The provider's idle read loop now polls in short slices through this
/// helper instead of blocking: each slice either reports the socket
/// ready, a tick (nothing yet — the caller updates the elapsed-time
/// status row), an interrupt key, or a live-input byte to echo. When the
/// caller has seen enough consecutive ticks (SILENCE_BEFORE_WATCH), stdin
/// joins the poll: Esc/Ctrl-C fails the wait as .cancelled (surfaced as
/// error.EscCancelled — the SAME cancel/recall path an in-stream Esc
/// takes), any other byte is handed back so the REPL can ECHO it — typing
/// during a stall used to vanish into a silent stash. Healthy streams
/// (gaps under the threshold) keep the event-driven esc probe untouched.
const std = @import("std");

pub const SliceResult = union(enum) {
    /// Socket has data (or poll failed — the blocking read plus the stall
    /// watchdog remain the backstop).
    ready,
    /// Nothing this slice. The caller accumulates silence and reports
    /// elapsed time upstream so a stalled gateway is VISIBLE.
    tick,
    cancelled,
    input: u8,
};

pub const POLL_SLICE_MS: i32 = 100;
/// Continuous socket silence after which the caller lets stdin join the
/// poll. Healthy inter-chunk gaps stay below it; only real stalls (or
/// long thinking pauses) watch stdin, where typed lines ride the pending
/// queue instead of the live dim echo.
pub const SILENCE_BEFORE_WATCH_MS: i32 = 400;

/// One poll slice: socket + (optionally, once the caller has accumulated
/// SILENCE_BEFORE_WATCH_MS of ticks) stdin.
///
/// Same-thread contract: the only other stdin consumer during a stream
/// is escProbe, which runs on this same thread between events and always
/// drains its buffered reader — so a raw fd-0 read here can neither race
/// nor reorder bytes with it.
pub fn waitSlice(sock_fd: std.c.fd_t, watch_stdin: bool) SliceResult {
    var pfds = [2]std.c.pollfd{
        .{ .fd = sock_fd, .events = std.c.POLL.IN, .revents = 0 },
        .{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 },
    };
    const nfds: std.c.nfds_t = if (watch_stdin) 2 else 1;
    const n = std.c.poll(&pfds, nfds, POLL_SLICE_MS);
    if (n < 0) return .ready; // let the blocking read + watchdog handle it
    if (n == 0) return .tick;
    if ((pfds[0].revents & std.c.POLL.IN) != 0) return .ready;
    if (nfds == 2 and (pfds[1].revents & std.c.POLL.IN) != 0) {
        var b: [1]u8 = undefined;
        const got = std.posix.read(0, &b) catch return .ready;
        if (got == 0) return .ready; // stdin EOF (pipe): stop watching
        // Esc or Ctrl-C cancel (same keys the in-stream probe treats as
        // cancel); every other byte goes back as live input so the REPL
        // can echo it.
        if (b[0] == 0x1b or b[0] == 0x03) return .cancelled;
        return .{ .input = b[0] };
    }
    return .tick;
}

test "waitSlice reports ready when the fd has data" {
    // A pipe stands in for the socket: data written to it must read ready.
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SkipZigTest;
    defer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }
    _ = std.c.write(fds[1], "x", 1);
    try std.testing.expect(waitSlice(fds[0], false) == .ready);
}
