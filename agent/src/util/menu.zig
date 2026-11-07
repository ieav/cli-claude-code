/// Interactive arrow-key menu for the REPL (raw terminal mode).
/// Keys: arrow up/down or vim k/j to move, Enter to select, Esc (or q) to
/// cancel, digits 1-9 to jump. On a TTY a lone ESC is distinguished from
/// arrow sequences (ESC [ A/B) by polling for follow-up bytes with a short
/// timeout; on non-TTY stdin (pipes/tests) all bytes are already buffered,
/// so the reader never blocks and sequences are read directly.
const std = @import("std");

pub const Key = union(enum) {
    up,
    down,
    enter,
    quit,
    digit: u8,
    ignore,
};

/// Map a single non-escape byte. vim convention: k = up, j = down.
pub fn parseKey(b: u8) Key {
    return switch (b) {
        'k' => .up,
        'j' => .down,
        '\r', '\n' => .enter,
        'q', 0x1b => .quit,
        '1'...'9' => .{ .digit = b - '1' },
        else => .ignore,
    };
}

var is_tty = false;

/// Read one logical key. ESC handling: in raw TTY mode a lone ESC is
/// followed by nothing (poll times out) -> quit; ESC [ A/B -> up/down.
pub fn readKey(r: *std.Io.Reader) !Key {
    const c = r.takeByte() catch |err| {
        if (err == error.EndOfStream) return .quit;
        return err;
    };
    if (c != 0x1b) return parseKey(c);

    // Arrow keys arrive as ESC [ A all at once — one underlying read pulls
    // all three bytes into the reader's own buffer. Check that buffer FIRST;
    // only when it is empty do we poll the fd to distinguish a lone ESC
    // (user pressed Esc alone) from a sequence split across reads.
    // Polling the fd while bytes sit in the buffer misread every arrow key
    // as a lone ESC — the on-TTY bug where arrow navigation "didn't work".
    if (r.bufferedLen() == 0) {
        if (is_tty) {
            var pfd = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
            const ready = std.c.poll(&pfd, 1, 25);
            if (ready <= 0 or (pfd[0].revents & std.c.POLL.IN) == 0) return .quit;
        }
    }

    const next = r.takeByte() catch return .quit;
    if (next != '[') return parseKey(next); // ESC followed by a normal key
    const final = r.takeByte() catch return .quit;
    return switch (final) {
        'A' => .up,
        'B' => .down,
        else => .ignore, // left/right/Home/etc unused
    };
}

pub const RawGuard = struct {
    orig: std.c.termios = undefined,
    active: bool = false,
    installed_signal: bool = false,
    installed_mouse: bool = false,

    pub fn enter(self: *RawGuard) void {
        self.enterImpl(false);
    }

    /// Raw mode with ISIG off: Ctrl-C/Ctrl-Z arrive as plain bytes the
    /// caller handles (e.g. double-Ctrl-C graceful exit) instead of the
    /// line discipline turning them into process-killing signals.
    pub fn enterNoSig(self: *RawGuard) void {
        self.enterImpl(true);
    }

    fn enterImpl(self: *RawGuard, no_sig: bool) void {
        if (std.c.tcgetattr(0, &self.orig) != 0) return; // not a TTY (pipe)
        var raw = self.orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        if (no_sig) raw.lflag.ISIG = false;
        // IEXTEN off: the discipline otherwise consumes ^O (VDISCARD),
        // ^V (VLNEXT) ITSELF — the byte never reaches the app (the Ctrl+O
        // verbosity toggle silently dead, 2026-11-07). IXON off likewise:
        // ^S/^Q are flow control, not keys.
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        // Deliver Enter verbatim as CR. The line discipline's ICRNL flag
        // (on in most cooked terminals) rewrites every \r to \n before the
        // program sees it — the editor needs \r=submit vs \n=newline to be
        // distinguishable (Ctrl+J / Shift+Enter).
        raw.iflag.ICRNL = false;
        raw.cc[@backingInt(std.c.V.MIN)] = 1;
        raw.cc[@backingInt(std.c.V.TIME)] = 0;
        if (std.c.tcsetattr(0, .NOW, &raw) == 0) self.active = true;
        // Crash/kill-safety: without a handler a SIGINT/SIGSEGV in raw mode
        // left the terminal echo-less and unusable after the process died.
        // NESTING (session guard + menu/confirm guards since 2026-11-06):
        // only the OUTERMOST guard owns the signal-restore slot — a nested
        // guard's orig is already raw, and on its crash-restore the process
        // would die leaving the terminal raw.
        if (self.active and signal_saved == null) {
            installSignalRestore(&self.orig);
            self.installed_signal = true;
        }
        // SGR mouse reporting (P4c): click-to-expand etc. Same outermost-
        // only ownership as the signal slot — a nested guard's restore
        // must not strip mouse from the still-live session.
        if (self.active and !mouse_on) {
            mouseWrite("\x1b[?1000h\x1b[?1006h");
            mouse_on = true;
            self.installed_mouse = true;
        }
    }

    pub fn restore(self: *RawGuard) void {
        if (self.installed_mouse) {
            mouseWrite("\x1b[?1000l\x1b[?1006l");
            mouse_on = false;
        }
        if (self.active) _ = std.c.tcsetattr(0, .NOW, &self.orig);
        if (self.installed_signal) removeSignalRestore();
    }
};

/// Whether SGR mouse reporting is currently pushed (CookedGuard suspends
/// it around line reads so clicks cannot inject escape bytes into y/N
/// answers).
var mouse_on: bool = false;

/// Raw syscall write to stdout — no Io/allocator needed (guard context),
/// and async-signal-safe for the crash restore path.
fn mouseWrite(bytes: []const u8) void {
    const n = std.c.write(1, bytes.ptr, bytes.len);
    _ = n;
}

/// Temporary COOKED-with-echo mode for one confirmation read (y/N gates,
/// /rewind confirm) inside a session that is otherwise raw the whole way
/// (see repl.run's session RawGuard). Raw mode delivers Enter as \r with
/// no echo — a streamDelimiter(.., '\n') read would block forever and the
/// user would type blind. Enter/restore is a no-op on non-TTY stdin.
pub const CookedGuard = struct {
    orig: std.c.termios = undefined,
    active: bool = false,

    pub fn enter(self: *CookedGuard) void {
        if (std.c.tcgetattr(0, &self.orig) != 0) return; // not a TTY (pipe)
        var cooked = self.orig;
        cooked.lflag.ICANON = true; // driver line-edits (backspace works)
        cooked.lflag.ECHO = true; // the user sees what they type
        cooked.iflag.ICRNL = true; // Enter becomes \n — ends the read
        // Suspend mouse reporting for the read: a click here would inject
        // the whole SGR sequence into the answer as garbage text.
        if (mouse_on) mouseWrite("\x1b[?1000l\x1b[?1006l");
        if (std.c.tcsetattr(0, .NOW, &cooked) == 0) self.active = true;
    }

    pub fn restore(self: *CookedGuard) void {
        if (self.active) _ = std.c.tcsetattr(0, .NOW, &self.orig);
        if (self.active and mouse_on == false) {
            // Session guard still wants mouse — push it back.
            mouseWrite("\x1b[?1000h\x1b[?1006h");
            mouse_on = true;
        }
    }
};

/// Saved terminal settings for the signal handler. One slot, owned by the
/// OUTERMOST active guard (session guard in repl.run since 2026-11-06);
/// nested menu/confirm guards never overwrite it.
var signal_saved: ?std.c.termios = null;

fn restoreFromSignal(sig: std.posix.SIG) callconv(.c) void {
    if (signal_saved) |*t| {
        // Async-signal-safety: ONLY tcsetattr here. Writing terminal
        // sequences (mouse-disable etc.) can BLOCK on a full pty buffer
        // while the parent isn't reading — the process then wedges inside
        // the signal handler and never reaches re-raise (the 2026-11-07
        // suite-hang root cause). The terminal's mouse mode leaks on crash;
        // it self-clears on most terminal resets and is cosmetic only.
        _ = std.c.tcsetattr(0, .NOW, t);
        // Restore the default disposition and re-raise so the exit status
        // still reflects the signal instead of swallowing it.
        const dfl_act: std.posix.Sigaction = .{
            .handler = .{ .handler = @ptrFromInt(0) },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(sig, &dfl_act, null);
        std.posix.raise(sig) catch {};
    }
}

fn installSignalRestore(orig: *const std.c.termios) void {
    signal_saved = orig.*;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = restoreFromSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn removeSignalRestore() void {
    signal_saved = null;
    const dfl_act: std.posix.Sigaction = .{
        .handler = .{ .handler = @ptrFromInt(0) },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &dfl_act, null);
    std.posix.sigaction(.TERM, &dfl_act, null);
}

fn render(w: *std.Io.Writer, title: []const u8, items: []const []const u8, idx: usize) !void {
    // Move back to the top of the previous frame (title + items + hint),
    // then redraw every line.
    const lines_up = items.len + 2;
    var buf: [32]u8 = undefined;
    const up = std.fmt.bufPrint(&buf, "\x1b[{d}A\x1b[J", .{lines_up}) catch "";
    try w.writeAll(up);
    try w.print("{s}\n", .{title});
    for (items, 0..) |item, i| {
        if (i == idx) {
            try w.print("  \x1b[36m❯ {s}\x1b[0m\n", .{item});
        } else {
            try w.print("    {s}\n", .{item});
        }
    }
    try w.writeAll("  ↑↓/jk 移动 · Enter 确认 · Esc 取消\n");
}

/// Show an interactive menu. Returns the selected index, or null on cancel.
pub fn select(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    title: []const u8,
    items: []const []const u8,
    start: usize,
) !?usize {
    if (items.len == 0) return null; // @min(start, len-1) would underflow
    var guard = RawGuard{};
    guard.enter();
    defer guard.restore();
    is_tty = guard.active;

    var idx = @min(start, items.len - 1);
    try render(w, title, items, idx);
    try std.Io.File.Writer.flush(file_writer);

    while (true) {
        const key = readKey(r) catch return null;
        switch (key) {
            .up => idx = (idx + items.len - 1) % items.len,
            .down => idx = (idx + 1) % items.len,
            .digit => |d| {
                if (d < items.len) idx = d;
            },
            .enter => {
                try w.print("\n  已选: {s}\n", .{items[idx]});
                try std.Io.File.Writer.flush(file_writer);
                return idx;
            },
            .quit => {
                try w.writeAll("\n  [取消]\n");
                try std.Io.File.Writer.flush(file_writer);
                return null;
            },
            .ignore => continue, // junk key: no re-render (a piped byte stream used to redraw a frame per byte)
        }
        try render(w, title, items, idx);
        try std.Io.File.Writer.flush(file_writer);
    }
}

/// Interactive pickers need BOTH ends interactive: stdin piped spins the
/// selector on the byte stream, stdout piped (ziv | cat) renders frames
/// into the pipe while the user types blind.
pub fn isTty() bool {
    return std.c.isatty(0) == 1 and std.c.isatty(1) == 1;
}

/// Read one line of text (cooked mode restored first) — for entering values
/// after a menu selection.
pub fn readLine(r: *std.Io.Reader, w: *std.Io.Writer, file_writer: *std.Io.File.Writer, prompt: []const u8, buf: []u8) ![]const u8 {
    try w.print("{s}", .{prompt});
    try std.Io.File.Writer.flush(file_writer);
    // CR or LF both end a line (RawGuard disables ICRNL, so a terminal
    // Enter arrives as \r); a CRLF pair counts as one terminator.
    var n: usize = 0;
    while (true) {
        const avail = r.peekGreedy(1) catch break;
        if (avail.len == 0) break; // EOF
        const c = avail[0];
        if (c == '\r' or c == '\n') {
            r.toss(1);
            if (c == '\r') {
                const a2 = r.peekGreedy(1) catch break;
                if (a2.len > 0 and a2[0] == '\n') r.toss(1);
            }
            break;
        }
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
        }
        r.toss(1);
    }
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

test "parseKey mappings" {
    try std.testing.expect(parseKey('\r') == .enter);
    try std.testing.expect(parseKey('\n') == .enter);
    try std.testing.expect(parseKey('q') == .quit);
    try std.testing.expect(parseKey(0x1b) == .quit);
    try std.testing.expect(parseKey('k') == .up);
    try std.testing.expect(parseKey('j') == .down);
    const k = parseKey('2');
    try std.testing.expect(k == .digit);
    try std.testing.expect(k.digit == 1);
    try std.testing.expect(parseKey('x') == .ignore);
}

test "readKey parses arrow sequences from buffered input (non-tty path)" {
    is_tty = false; // bytes are pre-buffered; no poll needed
    var seq = std.Io.Reader.fixed("\x1b[A\x1b[B\rq");
    try std.testing.expect((try readKey(&seq)) == .up);
    try std.testing.expect((try readKey(&seq)) == .down);
    try std.testing.expect((try readKey(&seq)) == .enter);
    try std.testing.expect((try readKey(&seq)) == .quit);

    // Lone ESC at end of stream: takeByte hits EOF -> quit.
    var esc_only = std.Io.Reader.fixed("\x1b");
    try std.testing.expect((try readKey(&esc_only)) == .quit);
}

test "readKey resolves buffered arrows in tty mode without polling the fd" {
    // The real-terminal case that broke arrow keys: the whole ESC [ A
    // sequence sits in the reader buffer while the fd has no pending
    // bytes — poll would time out and misread it as a lone ESC.
    is_tty = true;
    var seq = std.Io.Reader.fixed("\x1b[A\x1b[B");
    try std.testing.expect((try readKey(&seq)) == .up);
    try std.testing.expect((try readKey(&seq)) == .down);
    is_tty = false;
}
