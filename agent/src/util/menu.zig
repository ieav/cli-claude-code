/// Interactive arrow-key menu for the REPL (raw terminal mode).
/// Keys: arrow up/down or vim k/j to move, Enter to select, Esc (or q) to
/// cancel, digits 1-9 to jump. On a TTY a lone ESC is distinguished from
/// arrow sequences (ESC [ A/B) by polling for follow-up bytes with a short
/// timeout; on non-TTY stdin (pipes/tests) all bytes are already buffered,
/// so the reader never blocks and sequences are read directly.
const std = @import("std");
const termio = @import("termio.zig");
const builtin = @import("builtin");
const wincompat = @import("./wincompat.zig");

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
            const ready = termio.pollInput(25);
            if (ready <= 0) return .quit;
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
    orig: termio.Mode = undefined,
    active: bool = false,
    installed_signal: bool = false,

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
        // Platform seam (termio): posix keeps the termios choreography
        // (IEXTEN/IXON/ICRNL notes live there now); windows is
        // SetConsoleMode. False = not a TTY (pipe) — quiet no-op.
        if (termio.rawEnter(&self.orig, no_sig)) self.active = true;
        // Crash/kill-safety: without a handler a SIGINT/SIGSEGV in raw mode
        // left the terminal echo-less and unusable after the process died.
        // NESTING (session guard + menu/confirm guards since 2026-11-06):
        // only the OUTERMOST guard owns the signal-restore slot — a nested
        // guard's orig is already raw, and on its crash-restore the process
        // would die leaving the terminal raw.
        if (builtin.os.tag != .windows) {
            if (self.active and signal_saved == null) {
                installSignalRestore(&self.orig);
                self.installed_signal = true;
            }
        }
        // NO SGR mouse reporting, ever: enabling ?1000/?1006 makes the
        // TERMINAL stop doing native click-drag text selection — copy from
        // the transcript became impossible (2026-11-07 regression, P4c
        // reverted). Unknown CSI sequences still arrive never; if some
        // other tool left mouse on, the editor swallows the bytes.
    }

    pub fn restore(self: *RawGuard) void {
        if (self.active) termio.rawRestore(&self.orig);
        if (self.installed_signal) removeSignalRestore();
    }
};

/// Temporary COOKED-with-echo mode for one confirmation read (y/N gates,
/// /rewind confirm) inside a session that is otherwise raw the whole way
/// (see repl.run's session RawGuard). Raw mode delivers Enter as \r with
/// no echo — a streamDelimiter(.., '\n') read would block forever and the
/// user would type blind. Enter/restore is a no-op on non-TTY stdin.
pub const CookedGuard = struct {
    orig: termio.Mode = undefined,
    active: bool = false,

    pub fn enter(self: *CookedGuard) void {
        if (termio.cookedEnter(&self.orig)) self.active = true;
    }

    pub fn restore(self: *CookedGuard) void {
        if (self.active) termio.rawRestore(&self.orig);
    }
};

/// Saved terminal settings for the signal handler. One slot, owned by the
/// OUTERMOST active guard (session guard in repl.run since 2026-11-06);
/// nested menu/confirm guards never overwrite it.
var signal_saved: ?(if (builtin.os.tag == .windows) u0 else std.c.termios) = null;

fn restoreFromSignal(sig: std.posix.SIG) callconv(.c) void {
    if (builtin.os.tag == .windows) return;
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

fn installSignalRestore(orig: *const termio.Mode) void {
    if (builtin.os.tag == .windows) {
        // L1: SetConsoleCtrlHandler (T7.1 verification)
    } else {
        installSignalRestorePosix(orig);
    }
}

fn installSignalRestorePosix(orig: *const std.c.termios) void {
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
    if (builtin.os.tag == .windows) {
        // L1
    } else {
        removeSignalRestorePosix();
    }
}

fn removeSignalRestorePosix() void {
    signal_saved = null;
    const dfl_act: std.posix.Sigaction = .{
        .handler = .{ .handler = @ptrFromInt(0) },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &dfl_act, null);
    std.posix.sigaction(.TERM, &dfl_act, null);
}

fn renderFirst(w: *std.Io.Writer, title: []const u8, items: []const []const u8, idx: usize) !void {
    // FIRST frame: paint downward from the cursor, NO scroll-up — the
    // rows above belong to the caller (a parent menu's frame tail, the
    // banner, the transcript). The old shared render() scrolled up on
    // the first frame too, eating the parent's tail rows — the layered
    // ghosting when entering/leaving /config submenus.
    try w.writeAll("\r\x1b[J");
    try paintFrame(w, title, items, idx);
}

var last_frame_rows: usize = 0;

fn frameRows(items: []const []const u8, idx: usize) usize {
    // title + items (+ selected hint) + control-hint row.
    var rows = items.len + 2;
    if (show_hints and hint_items.len > idx and hint_items[idx].len > 0) rows += 1;
    return rows;
}

fn render(w: *std.Io.Writer, title: []const u8, items: []const []const u8, idx: usize) !void {
    // Repaint: lift to the PREVIOUS frame's top by its own row count
    // (hint rows come and go with the selection — a fixed items.len+2
    // miscounts and smears), clear, redraw.
    var buf: [32]u8 = undefined;
    const up = std.fmt.bufPrint(&buf, "\x1b[{d}A\x1b[J", .{last_frame_rows}) catch "";
    try w.writeAll(up);
    try paintFrame(w, title, items, idx);
    last_frame_rows = frameRows(items, idx);
}

var show_hints: bool = false;
var hint_items: []const []const u8 = &.{};

fn paintFrame(w: *std.Io.Writer, title: []const u8, items: []const []const u8, idx: usize) !void {
    try w.print("{s}\n", .{title});
    for (items, 0..) |item, i| {
        if (i == idx) {
            try w.print("  \x1b[36m❯ {s}\x1b[0m\n", .{item});
            if (show_hints and hint_items.len > i and hint_items[i].len > 0) {
                try w.print("      \x1b[2m{s}\x1b[0m\n", .{hint_items[i]});
            }
        } else {
            try w.print("    {s}\n", .{item});
        }
    }
    try w.writeAll("  ↑↓/jk 移动 · 1-9 直达 · Enter 确认 · Esc 取消\n");
}

/// select with per-item dim hints (one line under the selected item).
pub fn selectWithHints(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    title: []const u8,
    items: []const []const u8,
    hints: []const []const u8,
    start: usize,
) !?usize {
    return selectInner(w, r, file_writer, title, items, start, true, hints);
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
    return selectInner(w, r, file_writer, title, items, start, false, &.{});
}

fn selectInner(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    title: []const u8,
    items: []const []const u8,
    start: usize,
    with_hints: bool,
    hints: []const []const u8,
) !?usize {
    if (items.len == 0) return null; // @min(start, len-1) would underflow
    var guard = RawGuard{};
    guard.enter();
    defer guard.restore();
    is_tty = guard.active;

    // MODAL 生命周期（TUI v2）：进入=解除 region（流内自绘）；退出=清残
    // 留+规范重画输入区。Esc/Enter/错误三条出口都走 modalExit——菜单
    // 残留类问题的收口点。
    const lineinput = @import("lineinput.zig");
    lineinput.modalEnter(w);
    defer lineinput.modalExit(w);

    show_hints = with_hints and hints.len == items.len;
    hint_items = hints;
    var idx = @min(start, items.len - 1);
    try renderFirst(w, title, items, idx);
    last_frame_rows = frameRows(items, idx);
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
    return wincompat.isTtyStdinStdout();
}

/// Read one line of text — for entering values after a menu selection.
/// Runs in SESSION-RAW no-echo mode, so it owns its own minimal line
/// editing: echo each printable byte, backspace edits, Esc/Ctrl-C cancel
/// (returns null — distinct from the empty-but-submitted Enter so a
/// multi-field edit session can abort WHOLE on the first field), escape
/// sequences swallowed, other control bytes dropped. Invariant: only
/// printable bytes ever enter the value buffer.
pub fn readLine(r: *std.Io.Reader, w: *std.Io.Writer, file_writer: *std.Io.File.Writer, prompt: []const u8, buf: []u8) !?[]const u8 {
    try w.print("{s}", .{prompt});
    try std.Io.File.Writer.flush(file_writer);
    // CR or LF both end a line (RawGuard disables ICRNL, so a terminal
    // Enter arrives as \r); a CRLF pair counts as one terminator.
    // Esc cancels: this read runs in SESSION-RAW no-echo mode (select's
    // own guard has restored by now), so without this branch Esc was
    // appended to the value as an invisible literal byte and the user
    // had no way out but Enter (2026-11-07 /config 报障). Empty return
    // is every caller's existing "no change, back to menu" path.
    var n: usize = 0;
    while (true) {
        const avail = r.peekGreedy(1) catch break;
        if (avail.len == 0) break; // EOF
        const c = avail[0];
        if (c == '\r' or c == '\n') {
            r.toss(1);
            // CRLF pair (piped/pasted input arrives with both bytes
            // buffered): swallow the LF then. A live raw TTY delivers
            // Enter as a lone CR with NOTHING behind it — peeking there
            // blocks until the next keystroke and Enter looks dead
            // (the「回车没反应」root cause, 2026-11-07 D1).
            if (c == '\r' and r.bufferedLen() > 0) {
                const a2 = r.peekGreedy(1) catch break;
                if (a2.len > 0 and a2[0] == '\n') r.toss(1);
            }
            std.Io.Writer.writeAll(w, "\n") catch {};
            std.Io.File.Writer.flush(file_writer) catch {};
            break;
        }
        if (c == 0x1b) {
            r.toss(1);
            if (escTailIsSequence(r)) continue; // arrow/mouse bytes eaten
            std.Io.Writer.writeAll(w, "\n  [已取消]\n") catch {};
            std.Io.File.Writer.flush(file_writer) catch {};
            return null;
        }
        if (c == 0x7f or c == 0x08) { // backspace: edit, never data
            r.toss(1);
            if (n > 0) {
                n -= 1;
                std.Io.Writer.writeAll(w, "\x08 \x08") catch {};
                std.Io.File.Writer.flush(file_writer) catch {};
            }
            continue;
        }
        if (c == 0x03) { // Ctrl-C in session-raw (ISIG off): cancel, not data
            r.toss(1);
            std.Io.Writer.writeAll(w, "\n  [已取消]\n") catch {};
            std.Io.File.Writer.flush(file_writer) catch {};
            return null;
        }
        if (c < 0x20) { // other control bytes (Tab etc.) never enter the value
            r.toss(1);
            continue;
        }
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
            // Echo: this read runs in session-raw NO-ECHO mode — without
            // it the user types blind (same defect family as the Esc hole).
            std.Io.Writer.print(w, "{c}", .{c}) catch {};
            std.Io.File.Writer.flush(file_writer) catch {};
        }
        r.toss(1);
    }
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

/// After tossing a leading ESC: swallow a full escape sequence and return
/// true, or report a lone Esc (false). Same lone-Esc litmus as readKey —
/// buffered follow-up bytes = sequence; a quiet fd within 25ms = lone key.
/// CSI runs to its final byte (0x40..0x7E, covering arrows/Home and SGR
/// mouse clicks — a click at a value prompt must not inject its bytes into
/// the answer); SS3 (ESC O x) and Alt-modified keys take one byte. The
/// 16-byte CSI cap keeps a garbage stream from spinning forever.
fn escTailIsSequence(r: *std.Io.Reader) bool {
    if (r.bufferedLen() == 0) {
        if (!is_tty) return false; // piped/tests: bytes all pre-buffered
        const ready = termio.pollInput(25);
        if (ready <= 0) return false;
    }
    const b = r.takeByte() catch return true;
    if (b == 'O') {
        _ = r.takeByte() catch {};
        return true;
    }
    if (b != '[') return true; // Alt+key — the key itself, swallowed
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const f = r.takeByte() catch return true;
        if (f >= 0x40 and f <= 0x7E) return true;
    }
    return true;
}

test "readLine: lone Esc cancels, escape sequences are swallowed" {
    // The /config value-entry hole (2026-11-07): readLine ran in session
    // raw no-echo mode and only ended on CR/LF — Esc was appended to the
    // value as a literal byte (invisible, unfreshable), and arrow keys /
    // SGR mouse clicks injected their ESC[... bytes into it. Lone Esc now
    // returns empty (every caller's no-change path); sequences are eaten.
    is_tty = false; // piped: bytes pre-buffered, no poll needed

    // Minimal rig: readLine flushes a real File.Writer (to /dev/null).
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    const devnull = try std.Io.Dir.openFileAbsolute(io_state.io(), "/dev/null", .{ .mode = .write_only });
    defer devnull.close(io_state.io());
    var fw_buf: [64]u8 = undefined;
    var fw = std.Io.File.Writer.initStreaming(devnull, io_state.io(), &fw_buf);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    // Lone Esc with nothing typed → cancel (null).
    var r1 = std.Io.Reader.fixed("\x1b");
    var b1: [16]u8 = undefined;
    try std.testing.expect((try readLine(&r1, &aw.writer, &fw, "> ", &b1)) == null);

    // Partial input then Esc → cancel discards the partial text.
    aw.clearRetainingCapacity();
    var r2 = std.Io.Reader.fixed("81\x1b");
    var b2: [16]u8 = undefined;
    try std.testing.expect((try readLine(&r2, &aw.writer, &fw, "> ", &b2)) == null);

    // Arrow key mid-typing: sequence swallowed, digits kept.
    aw.clearRetainingCapacity();
    var r3 = std.Io.Reader.fixed("1\x1b[D2\r");
    var b3: [16]u8 = undefined;
    try std.testing.expectEqualStrings("12", (try readLine(&r3, &aw.writer, &fw, "> ", &b3)).?);

    // SGR mouse click injection: whole sequence eaten, value intact.
    aw.clearRetainingCapacity();
    var r4 = std.Io.Reader.fixed("\x1b[<0;5;7M8\r");
    var b4: [16]u8 = undefined;
    try std.testing.expectEqualStrings("8", (try readLine(&r4, &aw.writer, &fw, "> ", &b4)).?);

    // Backspace edits (never data); Tab dropped; typed chars echoed.
    // "19"⌫ → "1"; Tab dropped; "2"⌫ → "1"; "8" → "18".
    aw.clearRetainingCapacity();
    var r5 = std.Io.Reader.fixed("19\x7f\t2\x088\r");
    var b5: [16]u8 = undefined;
    try std.testing.expectEqualStrings("18", (try readLine(&r5, &aw.writer, &fw, "> ", &b5)).?);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x08 \x08") != null);
    // Ctrl-C in session-raw (ISIG off) cancels like Esc.
    aw.clearRetainingCapacity();
    var r6 = std.Io.Reader.fixed("12\x03");
    var b6: [16]u8 = undefined;
    try std.testing.expect((try readLine(&r6, &aw.writer, &fw, "> ", &b6)) == null);

    // CR terminates immediately (a lone CR must not wait for a follow-up
    // byte — on a live TTY that wait never ends, D1); CRLF when both bytes
    // are buffered counts as one terminator; a byte after CR stays for the
    // next reader.
    aw.clearRetainingCapacity();
    var r7 = std.Io.Reader.fixed("ab\r");
    var b7: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ab", (try readLine(&r7, &aw.writer, &fw, "> ", &b7)).?);
    aw.clearRetainingCapacity();
    var r8 = std.Io.Reader.fixed("cd\r\n");
    var b8: [16]u8 = undefined;
    try std.testing.expectEqualStrings("cd", (try readLine(&r8, &aw.writer, &fw, "> ", &b8)).?);
    aw.clearRetainingCapacity();
    var r9 = std.Io.Reader.fixed("ef\r9");
    var b9: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ef", (try readLine(&r9, &aw.writer, &fw, "> ", &b9)).?);
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
