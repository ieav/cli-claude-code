/// Raw-mode line editor for the REPL prompt: arrows move the cursor,
/// up/down walk input history, Backspace/Delete/Home/End work, UTF-8
/// advances per character. Multi-line input is supported Claude-Code-style:
///   - Enter submits; Ctrl+J, Option+Enter (ESC+CR/LF), Shift+Enter via
///     terminal keyboard protocols (CSI 13;2u), and a trailing `\`+Enter
///     all insert a newline.
///   - Bracketed paste (CSI 200~…201~) lands as ONE input with embedded
///     newlines (CRLF normalized), shown folded as `⏎ i/N` — the editor
///     renders the cursor's line, not the whole blob.
///   - Up/Down on a multi-line buffer move between lines; from the first
///     (or last) line they walk history as before.
/// Falls back to plain single-line reading on non-TTY stdin (pipes/scripts
/// keep the old behavior byte-for-byte).
const std = @import("std");
const lineinput_cmds = @import("slash_commands.zig");
const menu = @import("menu.zig");
const util_time = @import("time.zig");

/// Hard cap on a single input (typing or paste): guards the growth loop.
pub const INPUT_CAP: usize = 1 << 20; // 1 MiB

/// Rough display width: CJK/emoji count 2 columns, ASCII 1, UTF-8
/// continuation bytes 0 (they belong to the char that started them).
fn charWidth(b: u8) usize {
    if (b < 0x20) return 0;
    if (b < 0x80) return 1;
    if (b < 0xC0) return 0; // continuation
    if (b < 0xE0) return 1; // 2-byte scripts (latin ext etc.)
    if (b < 0xF8) return 2; // CJK / most emoji
    return 2;
}

fn strWidth(s: []const u8) usize {
    var w: usize = 0;
    for (s) |c| w += charWidth(c);
    return w;
}

/// Re-render a committed line in the history color so the user's sent
/// messages stay visually distinct in the conversation transcript (the
/// plain typed line blends into scrollback). Width-guarded: a line that
/// wrapped across terminal rows cannot be cleared with one 2K, so
/// overwidth/empty/multi-line commits keep the old bare-newline behavior.
fn renderCommitted(w: *std.Io.Writer, prompt: []const u8, line: []const u8, term_width: usize) !void {
    if (line.len == 0 or std.mem.indexOfScalar(u8, line, '\n') != null or
        strWidth(prompt) + strWidth(line) >= term_width)
    {
        try w.writeAll("\n");
        return;
    }
    try w.writeAll("\r\x1b[2K");
    try w.writeAll(prompt);
    try w.writeAll("\x1b[1;35m");
    try w.writeAll(line);
    try w.writeAll("\x1b[0m\n");
}

/// Terminal column count via TIOCGWINSZ; 80 as the conservative fallback.
fn termWidth() usize {
    var ws: std.c.winsize = undefined;
    if (std.c.ioctl(0, std.c.T.IOCGWINSZ, &ws) == 0 and ws.col > 0) return ws.col;
    return 80;
}

test "committed line re-renders magenta within the width budget" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try renderCommitted(&aw.writer, "> ", "hello", 80);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;35mhello\x1b[0m\n") != null);

    // CJK width counts 2 per char: 10 chars + prompt must still fit 80.
    var aw_cjk: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw_cjk.deinit();
    try renderCommitted(&aw_cjk.writer, "> ", "今天几号", 80);
    try std.testing.expect(std.mem.indexOf(u8, aw_cjk.written(), "\x1b[1;35m今天几号\x1b[0m\n") != null);

    // Overwidth, empty, and multi-line commits fall back to a bare newline.
    var aw2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw2.deinit();
    try renderCommitted(&aw2.writer, "> ", "hello", 7);
    try std.testing.expectEqualStrings("\n", aw2.written());

    var aw3: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw3.deinit();
    try renderCommitted(&aw3.writer, "> ", "", 80);
    try std.testing.expectEqualStrings("\n", aw3.written());

    var aw4: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw4.deinit();
    try renderCommitted(&aw4.writer, "> ", "a\nb", 80);
    try std.testing.expectEqualStrings("\n", aw4.written());
}

/// Step back one UTF-8 character from pos.
fn prevChar(buf: []const u8, pos: usize) usize {
    var p = pos;
    while (p > 0 and (buf[p - 1] & 0xC0) == 0x80) p -= 1;
    return if (p > 0) p - 1 else 0;
}

fn nextChar(buf: []const u8, pos: usize) usize {
    var p = pos;
    if (p < buf.len) p += 1;
    while (p < buf.len and (buf[p] & 0xC0) == 0x80) p += 1;
    return p;
}

/// ASCII case-insensitive substring test (for the reverse search).
fn ciContains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(hay[i + j]) == std.ascii.toLower(needle[j])) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

/// Snap a byte offset down to the start of the UTF-8 char containing it.
/// A boundary AFTER a complete char (buf[p-1] is a continuation byte that
/// belongs to a finished char) must NOT move — only a p sitting mid-char
/// (buf[p] itself a continuation byte) steps back. p == buf.len is always
/// a boundary (reading buf[p] there would be out of bounds — PTY recall
/// regression).
fn snapBack(buf: []const u8, pos: usize) usize {
    var p = @min(pos, buf.len);
    if (p == buf.len) return p;
    while (p > 0 and (buf[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

const LineSpan = struct { start: usize, end: usize };

/// Bounds of the line (newline-delimited span) containing `pos`.
fn lineOf(buf: []const u8, pos: usize) LineSpan {
    var s = @min(pos, buf.len);
    while (s > 0 and buf[s - 1] != '\n') s -= 1;
    var e = s;
    while (e < buf.len and buf[e] != '\n') e += 1;
    return .{ .start = s, .end = e };
}

/// Move one display line up (-1) or down (+1), keeping the byte column and
/// clamping to the target line's end. Null when already on the first/last
/// line (the caller falls back to history navigation — Claude-Code style).
fn moveVertically(buf: []const u8, pos: usize, dir: i8) ?usize {
    const cur = lineOf(buf, pos);
    const col = pos - cur.start;
    if (dir < 0) {
        if (cur.start == 0) return null;
        const prev = lineOf(buf, cur.start - 1);
        const np = prev.start + @min(col, prev.end - prev.start);
        return snapBack(buf, np);
    } else {
        if (cur.end >= buf.len) return null;
        const next = lineOf(buf, cur.end + 1);
        const np = next.start + @min(col, next.end - next.start);
        return snapBack(buf, np);
    }
}

/// What a parsed CSI sequence asks the editor to do.
const CsiAction = enum { up, down, left, right, home, end, delete, newline, paste_start, ignore };

/// Classify a CSI sequence body (without ESC [ — e.g. "A", "3~", "13;2u",
/// "200~"). Unknown sequences resolve to .ignore instead of leaking their
/// parameter bytes into the buffer as text.
fn classifyCsi(seq: []const u8) CsiAction {
    if (std.mem.eql(u8, seq, "A")) return .up;
    if (std.mem.eql(u8, seq, "B")) return .down;
    if (std.mem.eql(u8, seq, "C")) return .right;
    if (std.mem.eql(u8, seq, "D")) return .left;
    if (std.mem.eql(u8, seq, "H") or std.mem.eql(u8, seq, "1~")) return .home;
    if (std.mem.eql(u8, seq, "F") or std.mem.eql(u8, seq, "4~")) return .end;
    if (std.mem.eql(u8, seq, "3~")) return .delete;
    if (std.mem.eql(u8, seq, "200~")) return .paste_start;
    // Kitty / xterm modifyOtherKeys: Shift+Enter = 13;2u, Ctrl+Enter = 13;5u.
    if (seq.len >= 4 and std.mem.startsWith(u8, seq, "13;") and seq[seq.len - 1] == 'u') return .newline;
    return .ignore;
}

/// CRLF/CR normalization for pasted bytes: '\r' becomes '\n' and the '\n'
/// of a following CRLF pair is swallowed. Returns null for swallowed bytes.
fn pasteNormalize(pc: u8, skip_lf: *bool) ?u8 {
    if (pc == '\r') {
        skip_lf.* = true;
        return '\n';
    }
    if (pc == '\n' and skip_lf.*) {
        skip_lf.* = false;
        return null;
    }
    skip_lf.* = false;
    return pc;
}

/// Test hook: force the editor path even when stdin is not a TTY.
pub var force_editor = false;

// ── Esc-to-recall handshake (set by the REPL, consumed by readLine) ──

/// Borrowed text the next prompt should preload into the editor (Esc
/// interrupt / short-window recall of the last sent message). Caller keeps
/// ownership until it replaces the value.
pub var recall_text: ?[]const u8 = null;
/// Gate for the PRELOAD only: a normal completed turn leaves recall_text
/// armed (for the short-window Esc recall) but must NOT prefill the next
/// prompt — only an Esc INTERRUPT does that.
pub var recall_prefill = false;
/// When the last line was submitted (millis). The empty-prompt Esc recall
/// only fires within a short window after this.
pub var last_submit_ms: i64 = 0;

/// Type-ahead bytes typed while the LLM was generating (they must not be
/// lost just because we polled stdin for Esc). Replayed into the next
/// prompt by readLine.
pub var typeahead_buf: [256]u8 = undefined;
pub var typeahead_len: usize = 0;

/// Non-blocking Esc probe for the streaming callback: true when the user
/// pressed Esc (a following CSI sequence is swallowed so arrow keys don't
/// leak into the prompt). Any non-Esc bytes go to the type-ahead buffer.
/// Checks the reader's OWN buffer first — a burst "text…ESC" lands in one
/// read and the kernel fd goes dry, so polling fd alone never sees the Esc
/// (same trap menu.readKey fixed with its bufferedLen check).
pub fn escProbe(r: *std.Io.Reader) bool {
    if (r.bufferedLen() == 0) {
        var pfd = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&pfd, 1, 0) != 1 or (pfd[0].revents & std.c.POLL.IN) == 0) return false;
    }
    const c = r.takeByte() catch return false;
    if (c == 0x03) {
        // Ctrl-C during generation interrupts like Esc (generation runs in
        // raw mode with ISIG off, so the byte arrives here instead of as a
        // signal). Swallow an immediately-following second one so it cannot
        // leak into the next prompt.
        var p2 = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&p2, 1, 5) == 1 and (p2[0].revents & std.c.POLL.IN) != 0) {
            _ = r.takeByte() catch {};
        }
        return true;
    }
    if (c != 0x1b) {
        // Keep typed-ahead bytes (LF too — multi-line paste during
        // generation survives), but drop CR: its meaning ("submit") cannot
        // survive into a pre-filled buffer.
        if (c != '\r' and (c >= 0x20 or c == '\n') and typeahead_len < typeahead_buf.len) {
            typeahead_buf[typeahead_len] = c;
            typeahead_len += 1;
        }
        return false;
    }
    // Swallow a CSI sequence that follows promptly (arrow keys etc.). '['
    // sits INSIDE the final-byte range — test it first or the loop breaks
    // off at the introducer and leaks "A"/"3~" into the prompt.
    while (true) {
        var p2 = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&p2, 1, 5) != 1 or (p2[0].revents & std.c.POLL.IN) == 0) break;
        const b = r.takeByte() catch break;
        if (b == '[') continue; // CSI introducer
        if (b >= 0x40 and b <= 0x7E) break; // real final byte
    }
    return true;
}

const Editor = struct {
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    r: *std.Io.Reader,
    prompt: []const u8,
    buf: []u8,
    len: usize = 0,
    pos: usize = 0,
    /// Set in readLine: grow the buffer on overflow (typing and paste);
    /// tests construct the editor with a fixed buffer and no grower.
    grow: ?std.mem.Allocator = null,
    owned_buf: ?[]u8 = null, // the heap allocation behind buf when growing
    /// True while the line shows a HISTORY entry (up/down navigation): the
    /// line renders bold magenta so it is instantly tellable apart from a
    /// fresh draft. Editing drops back to the draft style.
    browsing: bool = false,

    fn render(self: *Editor) !void {
        try self.w.print("\r\x1b[2K{s}", .{self.prompt});
        const line = self.buf[0..self.len];
        const multi = std.mem.indexOfScalar(u8, line, '\n') != null;
        // Render the line the CURSOR is on, not the whole blob: editing any
        // line stays visible, and the fold marker carries the position.
        const span = lineOf(line, self.pos);
        const visible = line[span.start..span.end];

        if (self.browsing) try self.w.writeAll("\x1b[1;35m");
        // Highlight a leading slash command: the first token renders cyan
        // (dim if unknown), the rest of the line stays plain. Skipped while
        // browsing history — the inner reset would drop the magenta.
        if (!self.browsing and visible.len > 0 and span.start == 0 and line[0] == '/') {
            const tok_end = std.mem.indexOfScalar(u8, visible, ' ') orelse visible.len;
            const tok = visible[0..tok_end];
            const known = lineinput_cmds.isKnownCommand(tok);
            if (known) {
                try self.w.print("\x1b[36m{s}\x1b[0m{s}", .{ tok, visible[tok_end..] });
            } else {
                try self.w.print("\x1b[90m{s}\x1b[0m{s}", .{ tok, visible[tok_end..] });
            }
        } else {
            try self.w.writeAll(visible);
        }
        if (self.browsing) try self.w.writeAll("\x1b[0m");
        if (multi) {
            const line_idx = if (span.start == 0) 0 else std.mem.count(u8, line[0..span.start], "\n");
            const total = std.mem.count(u8, line, "\n");
            try self.w.print("\x1b[2m ⏎{d}/{d}\x1b[0m", .{ line_idx + 1, total + 1 });
        }
        // Park the cursor at the editing position (within the visible line).
        const vpos = self.pos - span.start;
        const tail_w = strWidth(visible[vpos..visible.len]);
        if (tail_w > 0) {
            var b: [16]u8 = undefined;
            const back = std.fmt.bufPrint(&b, "\x1b[{d}D", .{tail_w}) catch "";
            try self.w.writeAll(back);
        }
        try std.Io.File.Writer.flush(self.file_writer);
    }

    /// Grow the backing buffer to fit `extra` more bytes. No-op without a
    /// grower (fixed-buffer editor, tests) or past INPUT_CAP.
    fn ensureCapacity(self: *Editor, extra: usize) !void {
        if (self.len + extra <= self.buf.len) return;
        const g = self.grow orelse return;
        if (self.buf.len >= INPUT_CAP) return;
        var new_cap = self.buf.len;
        while (new_cap < self.len + extra and new_cap < INPUT_CAP) new_cap *= 2;
        if (new_cap < self.len + extra) new_cap = @min(INPUT_CAP, self.len + extra);
        const old = self.owned_buf orelse return;
        const nb = try g.realloc(old, new_cap);
        self.owned_buf = nb;
        self.buf = nb;
    }

    fn insertBytes(self: *Editor, bytes: []const u8) !void {
        if (self.len + bytes.len > self.buf.len) {
            try self.ensureCapacity(bytes.len);
            if (self.len + bytes.len > self.buf.len) return; // still capped
        }
        std.mem.copyBackwards(u8, self.buf[self.pos + bytes.len .. self.len + bytes.len], self.buf[self.pos..self.len]);
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
        self.len += bytes.len;
    }

    fn insert(self: *Editor, b: u8) !void {
        try self.insertBytes(&[1]u8{b});
    }

    fn backspace(self: *Editor) void {
        if (self.pos == 0) return;
        const start = prevChar(self.buf[0..self.len], self.pos);
        const cut = self.pos - start;
        std.mem.copyForwards(u8, self.buf[start .. self.len - cut], self.buf[self.pos..self.len]);
        self.len -= cut;
        self.pos = start;
    }

    /// Ctrl-W: delete back one WORD (whitespace-delimited, UTF-8 aware).
    fn deleteWordBack(self: *Editor) void {
        if (self.pos == 0) return;
        var p = self.pos;
        while (p > 0 and self.buf[p - 1] == ' ') p -= 1; // skip trailing spaces
        while (p > 0 and self.buf[p - 1] != ' ') p = prevChar(self.buf[0..self.len], p);
        const cut = self.pos - p;
        std.mem.copyForwards(u8, self.buf[p .. self.len - cut], self.buf[self.pos..self.len]);
        self.len -= cut;
        self.pos = p;
    }

    /// Ctrl-U: delete from cursor to line start.
    fn deleteToStart(self: *Editor) void {
        if (self.pos == 0) return;
        std.mem.copyForwards(u8, self.buf[0 .. self.len - self.pos], self.buf[self.pos..self.len]);
        self.len -= self.pos;
        self.pos = 0;
    }

    /// Ctrl-K: delete from cursor to line end.
    fn deleteToEnd(self: *Editor) void {
        self.len = self.pos;
    }

    fn deleteAt(self: *Editor) void {
        if (self.pos >= self.len) return;
        const end = nextChar(self.buf[0..self.len], self.pos);
        const cut = end - self.pos;
        std.mem.copyForwards(u8, self.buf[self.pos .. self.len - cut], self.buf[end..self.len]);
        self.len -= cut;
    }

    fn loadHistory(self: *Editor, item: []const u8) void {
        // History entries can be far larger than the fresh 8 KiB buffer
        // (a 1 MiB paste) — grow first instead of silently truncating the
        // recall (which used to splice a truncated twin back into history).
        self.ensureCapacity(item.len) catch {};
        const n = @min(item.len, self.buf.len);
        @memcpy(self.buf[0..n], item[0..n]);
        self.len = n;
        self.pos = snapBack(self.buf[0..n], n); // never park mid-UTF-8
    }

    /// Stream the bracketed-paste body into the buffer until the 201~
    /// terminator (matched byte-by-byte so a lone ESC inside the content
    /// survives), normalizing CRLF. Over-cap bytes are dropped, not fatal.
    fn pasteBody(self: *Editor) !void {
        const term = "\x1b[201~";
        var mi: usize = 0; // partial terminator match length
        var skip_lf = false;
        while (mi < term.len) {
            const pc = self.r.takeByte() catch {
                // EOF mid-paste: flush a partially matched terminator —
                // those bytes were real content (e.g. a trailing lone ESC),
                // not the marker.
                if (mi > 0) try self.pasteSlice(term[0..mi], &skip_lf);
                break;
            };
            if (pc == term[mi]) {
                mi += 1;
                continue;
            }
            if (mi > 0) {
                try self.pasteSlice(term[0..mi], &skip_lf);
                mi = 0;
            }
            if (pc == term[0]) {
                mi = 1;
                continue;
            }
            try self.pasteSlice(&[1]u8{pc}, &skip_lf);
        }
        self.browsing = false;
    }

    fn pasteSlice(self: *Editor, bytes: []const u8, skip_lf: *bool) !void {
        for (bytes) |pc| {
            const nb = pasteNormalize(pc, skip_lf) orelse continue;
            // Invisible control bytes (ESC, NUL, …) ride along in pasted
            // terminal output and would silently contaminate the message;
            // keep newline and tab only.
            if (nb < 0x20 and nb != '\t') continue;
            try self.insertBytes(&[1]u8{nb});
        }
    }
};

/// Consume the rest of a line that overflowed the caller's buffer, so the
/// next read starts at a fresh line instead of mid-content.
fn drainRestOfLine(r: *std.Io.Reader) void {
    var sink: [1024]u8 = undefined;
    while (true) {
        var sw = std.Io.Writer.fixed(&sink);
        _ = std.Io.Reader.streamDelimiter(r, &sw, '\n') catch return; // EOF / read error
        r.toss(1); // consume the delimiter streamDelimiter left buffered
        if (sw.end < sink.len) return; // end of line reached with room to spare
        // Sink filled exactly — the line may continue; check again.
    }
}

/// Read a line with full cursor editing and multi-line support. Returns an
/// allocator-owned slice (caller frees — it may exceed 4 KiB after a paste),
/// or null on EOF / Ctrl-D / double Ctrl-C on an empty line. `history`
/// receives committed non-empty lines and drives up/down navigation.
pub fn readLine(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    prompt: []const u8,
    history: *std.ArrayList([]u8),
    alloc: std.mem.Allocator,
) !?[]u8 {
    var guard = menu.RawGuard{};
    guard.enterNoSig();
    defer guard.restore();

    if (!guard.active and !force_editor) {
        // Non-TTY: behave exactly like the old reader, except an overlong
        // line is truncated instead of being mistaken for EOF — the old
        // path returned null (Goodbye!) and left the tail of the long line
        // polluting the next read.
        var buf: [4096]u8 = undefined;
        var bw = std.Io.Writer.fixed(&buf);
        const n = std.Io.Reader.streamDelimiter(r, &bw, '\n') catch |err| switch (err) {
            error.WriteFailed => {
                drainRestOfLine(r);
                return try alloc.dupe(u8, buf[0..]);
            },
            else => return null,
        };
        r.toss(1);
        return try alloc.dupe(u8, buf[0..n]);
    }

    // Advertise bracketed paste so multi-line pastes arrive wrapped in
    // 200~…201~ markers instead of being executed line by line.
    try w.writeAll("\x1b[?2004h");
    try std.Io.File.Writer.flush(file_writer);
    defer {
        w.writeAll("\x1b[?2004l") catch {};
        std.Io.File.Writer.flush(file_writer) catch {};
    }

    const initial = try alloc.alloc(u8, 8192);
    var ed = Editor{
        .w = w,
        .file_writer = file_writer,
        .r = r,
        .prompt = prompt,
        .buf = initial,
        .grow = alloc,
        .owned_buf = initial,
    };
    // ed.owned_buf stays current across growth reallocs — free THAT, never
    // a stale copy of the initial pointer.
    var submitted = false;
    defer if (!submitted) alloc.free(ed.owned_buf.?);

    var nav: ?usize = null; // history index while navigating
    var draft_owned: ?[]u8 = null; // pre-navigation draft (heap: line may be long)
    defer if (draft_owned) |d| alloc.free(d);
    var ctrl_c_at: i64 = 0; // last Ctrl-C press — two within 3s exit gracefully
    // Ctrl+R reverse search state.
    var search_on = false;
    var search_q: [128]u8 = undefined;
    var search_ql: usize = 0;
    var search_from: usize = 0; // history cursor (counts down from newest)
    var search_failed = false;

    // Open pre-filled: the recalled (Esc-INTERRUPTED) message first, then
    // any bytes typed ahead during generation. A normally completed turn
    // arms recall_text for the short-window Esc recall but does NOT
    // prefill — every prompt used to open with the previous message.
    if (recall_prefill) {
        recall_prefill = false;
        if (recall_text) |t| {
            ed.insertBytes(t) catch {};
        }
    }
    if (typeahead_len > 0) {
        ed.insertBytes(typeahead_buf[0..typeahead_len]) catch {};
        typeahead_len = 0;
    }

    try ed.render();
    while (true) {
        const c = ed.r.takeByte() catch return null;
        // Any other key breaks a pending double-Ctrl-C sequence.
        if (c != 0x03) ctrl_c_at = 0;

        // ── Ctrl+R reverse search mode ──
        if (search_on) {
            switch (c) {
                0x12 => { // Ctrl+R again: next older match
                    if (search_from > 0) search_from -= 1;
                },
                0x7f, 0x08 => { // shrink query, rematch from the top
                    if (search_ql > 0) search_ql -= 1;
                    search_from = history.items.len;
                },
                0x1b => { // Esc: leave search, keep the current match.
                    // Do NOT fall into the normal Esc branch — its seq2
                    // read BLOCKS for the next key (screen frozen on the
                    // search line) and an immediately following Enter
                    // would hit the Option+Enter newline path instead of
                    // submitting.
                    search_on = false;
                    try ed.render();
                    continue;
                },
                '\r' => { // Enter: accept — fall through to normal submit
                    search_on = false;
                },
                else => {
                    if (c >= 0x20 and search_ql < search_q.len) {
                        search_q[search_ql] = c;
                        search_ql += 1;
                        search_from = history.items.len;
                    } else {
                        search_on = false; // other control keys leave search
                    }
                },
            }
            if (search_on) {
                // (Re)find the newest match at/below search_from.
                search_failed = true;
                var i = @min(search_from, history.items.len);
                while (i > 0) {
                    i -= 1;
                    if (ciContains(history.items[i], search_q[0..search_ql])) {
                        ed.loadHistory(history.items[i]);
                        ed.browsing = true;
                        search_from = i;
                        search_failed = false;
                        break;
                    }
                }
                try ed.w.print("\r\x1b[2K(reverse-i-search)`{s}': ", .{search_q[0..search_ql]});
                if (search_failed and search_ql > 0) {
                    // (Empty query always matches the newest entry; red
                    // noise for it helped nobody.)
                    try ed.w.writeAll("\x1b[31m(failing)\x1b[0m");
                } else {
                    const span = lineOf(ed.buf[0..ed.len], @min(ed.pos, ed.len));
                    try ed.w.writeAll(ed.buf[span.start..span.end]);
                }
                try std.Io.File.Writer.flush(file_writer);
                continue;
            }
            // Search exited with a pending key ('\r'/Esc/other ctrl):
            // fall into the normal dispatch below.
        }
        if (c == 0x1b) {
            const seq2 = ed.r.takeByte() catch {
                // Lone Esc at an empty prompt, shortly after a submit:
                // recall the just-sent message back into the editor.
                if (ed.len == 0 and recall_text != null and
                    util_time.nowMillis() - last_submit_ms < 5000)
                {
                    ed.insertBytes(recall_text.?) catch {};
                    recall_text = null;
                    try ed.render();
                    continue;
                }
                try ed.render(); // lone ESC: ignore
                continue;
            };
            if (seq2 == '\r' or seq2 == '\n') {
                // Option/Alt+Enter: newline, not submit.
                try ed.insertBytes("\n");
                ed.browsing = false;
                try ed.render();
                continue;
            }
            if (seq2 != '[') continue; // other alt-keys: ignore
            // Collect the CSI body: params until a final byte (letter/~).
            var seq: [16]u8 = undefined;
            var sl: usize = 0;
            var final_seen = false;
            while (sl < seq.len) {
                const b = ed.r.takeByte() catch break;
                seq[sl] = b;
                sl += 1;
                if ((b >= 0x40 and b <= 0x7E) and b != ';') {
                    final_seen = true;
                    break;
                }
            }
            if (!final_seen) {
                try ed.render();
                continue; // truncated/garbage CSI: swallow
            }
            switch (classifyCsi(seq[0..sl])) {
                .right => {
                    if (ed.pos < ed.len) ed.pos = nextChar(ed.buf[0..ed.len], ed.pos);
                },
                .left => {
                    if (ed.pos > 0) ed.pos = prevChar(ed.buf[0..ed.len], ed.pos);
                },
                .up => {
                    // Multi-line buffer: move between lines first; from the
                    // first line, Up walks history as before.
                    if (std.mem.indexOfScalar(u8, ed.buf[0..ed.len], '\n') != null) {
                        if (moveVertically(ed.buf[0..ed.len], ed.pos, -1)) |np| {
                            ed.pos = np;
                            try ed.render();
                            continue;
                        }
                    }
                    if (history.items.len == 0) continue;
                    if (nav == null) {
                        // A stale draft from an earlier navigation round
                        // (↓ back to bottom, Ctrl-C) must be released before
                        // re-duping — overwriting the pointer leaked it.
                        if (draft_owned) |d| {
                            alloc.free(d);
                            draft_owned = null;
                        }
                        draft_owned = alloc.dupe(u8, ed.buf[0..ed.len]) catch null;
                        nav = history.items.len;
                    }
                    if (nav.? > 0) {
                        nav.? -= 1;
                        ed.loadHistory(history.items[nav.?]);
                        ed.browsing = true;
                    }
                },
                .down => {
                    if (std.mem.indexOfScalar(u8, ed.buf[0..ed.len], '\n') != null) {
                        if (moveVertically(ed.buf[0..ed.len], ed.pos, 1)) |np| {
                            ed.pos = np;
                            try ed.render();
                            continue;
                        }
                    }
                    if (nav == null) continue;
                    if (nav.? + 1 < history.items.len) {
                        nav.? += 1;
                        ed.loadHistory(history.items[nav.?]);
                    } else {
                        nav = null;
                        if (draft_owned) |d| ed.loadHistory(d);
                        ed.browsing = false;
                    }
                },
                .home => ed.pos = 0,
                .end => ed.pos = ed.len,
                .delete => ed.deleteAt(),
                .newline => {
                    // Shift/Ctrl+Enter via kitty / modifyOtherKeys protocols.
                    try ed.insertBytes("\n");
                    ed.browsing = false;
                },
                .paste_start => try ed.pasteBody(),
                .ignore => {},
            }
            try ed.render();
            continue;
        }
        switch (c) {
            '\r' => {
                if (ed.len > 0 and ed.buf[ed.len - 1] == '\\') {
                    // Trailing `\` + Enter = line continuation (Claude-Code
                    // fallback for terminals without Shift+Enter): drop the
                    // backslash, insert a newline, keep editing.
                    ed.len -= 1;
                    ed.pos = @min(ed.pos, ed.len);
                    try ed.insertBytes("\n");
                    ed.browsing = false;
                } else {
                    // Re-render the committed line in the history color so
                    // sent messages stay distinguishable in the transcript.
                    try renderCommitted(ed.w, ed.prompt, ed.buf[0..ed.len], termWidth());
                    try std.Io.File.Writer.flush(file_writer);
                    last_submit_ms = util_time.nowMillis();
                    recall_text = null; // submitted: recall window re-arms only via Esc interrupt
                    const line = ed.buf[0..ed.len];
                    if (line.len > 0 and (history.items.len == 0 or !std.mem.eql(u8, history.items[history.items.len - 1], line))) {
                        const duped = alloc.dupe(u8, line) catch null;
                        if (duped) |o| {
                            history.append(alloc, o) catch alloc.free(o);
                        }
                    }
                    submitted = true;
                    // Realloc down to the exact length so the caller can
                    // free() the returned slice directly; on failure dupe
                    // (never hand out a subslice of a larger allocation),
                    // and if even the dupe fails, release the buffer before
                    // propagating — submitted already skipped the defer.
                    const exact = alloc.realloc(ed.owned_buf.?, ed.len) catch blk: {
                        const dup = alloc.dupe(u8, line) catch {
                            alloc.free(ed.owned_buf.?);
                            return error.OutOfMemory;
                        };
                        alloc.free(ed.owned_buf.?);
                        break :blk dup;
                    };
                    return exact;
                }
            },
            '\n' => {
                // Ctrl+J (and terminals where Enter sends LF): literal
                // newline — raw-mode CR is the submit key.
                try ed.insertBytes("\n");
                ed.browsing = false;
            },
            0x7f, 0x08 => {
                ed.backspace();
                ed.browsing = false;
            },
            0x03 => {
                // Ctrl-C: a single press just clears the line (terminal users
                // often hit Ctrl-C reflexively, e.g. copy attempts). Two
                // presses within 3s return null = EOF, which the REPL treats
                // to the full session-end cleanup — same as /quit.
                const now = util_time.nowMillis();
                if (ctrl_c_at != 0 and now - ctrl_c_at <= 3000) {
                    try ed.w.writeAll("^C\n");
                    try std.Io.File.Writer.flush(file_writer);
                    return null;
                }
                ctrl_c_at = now;
                ed.len = 0;
                ed.pos = 0;
                nav = null;
                ed.browsing = false;
                try ed.w.writeAll("^C  (再按一次 Ctrl-C 退出)\n");
            },
            0x1a => {
                // Ctrl-Z: ISIG is off in raw mode, so suspend manually —
                // restore the terminal, stop with the default disposition,
                // then re-enter raw mode once the shell resumes us.
                if (guard.active) {
                    guard.restore();
                    const dfl_tstp: std.posix.Sigaction = .{
                        .handler = .{ .handler = @ptrFromInt(0) },
                        .mask = std.posix.sigemptyset(),
                        .flags = 0,
                    };
                    std.posix.sigaction(.TSTP, &dfl_tstp, null);
                    std.posix.raise(.TSTP) catch {};
                    guard.enterNoSig();
                }
            },
            0x04 => { // Ctrl-D: EOF on empty line, delete-forward otherwise
                if (ed.len == 0) {
                    try ed.w.writeAll("\n");
                    return null;
                }
                ed.deleteAt();
            },
            0x01 => ed.pos = 0, // Ctrl-A: line start
            0x05 => ed.pos = ed.len, // Ctrl-E: line end
            0x02 => { // Ctrl-B: back one char
                if (ed.pos > 0) ed.pos = prevChar(ed.buf[0..ed.len], ed.pos);
            },
            0x06 => { // Ctrl-F: forward one char
                if (ed.pos < ed.len) ed.pos = nextChar(ed.buf[0..ed.len], ed.pos);
            },
            0x17 => ed.deleteWordBack(), // Ctrl-W
            0x15 => ed.deleteToStart(), // Ctrl-U
            0x0b => ed.deleteToEnd(), // Ctrl-K
            0x12 => { // Ctrl+R: reverse history search (needs something to search)
                if (history.items.len > 0) {
                    search_on = true;
                    search_ql = 0;
                    search_from = history.items.len;
                    search_failed = false;
                }
            },
            else => {
                if (c >= 0x20) {
                    try ed.insert(c);
                    ed.browsing = false;
                }
            },
        }
        try ed.render();
    }
}

test "editor: insert, move left, insert, backspace, submit (forced path)" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList([]u8) = .empty;
    defer {
        for (history.items) |h| alloc.free(h);
        history.deinit(alloc);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    // Drive the pure buffer ops (the parts that don't need a terminal).
    var buf: [64]u8 = undefined;
    var ed = Editor{ .w = &aw.writer, .file_writer = undefined, .r = undefined, .prompt = ">", .buf = &buf };
    try ed.insert('a');
    try ed.insert('b');
    try ed.insert('c');
    try std.testing.expectEqualStrings("abc", ed.buf[0..ed.len]);
    ed.pos = prevChar(ed.buf[0..ed.len], ed.pos); // left -> after 'ab'
    try ed.insert('X'); // abXc
    try std.testing.expectEqualStrings("abXc", ed.buf[0..ed.len]);
    ed.backspace(); // abc
    try std.testing.expectEqualStrings("abc", ed.buf[0..ed.len]);
    ed.pos = nextChar(ed.buf[0..ed.len], ed.pos);
    try std.testing.expectEqual(@as(usize, 3), ed.pos);
    // UTF-8: append 中文 (3 bytes each) then walk back one char.
    for ("中") |b| try ed.insert(b);
    try std.testing.expectEqualStrings("abc中", ed.buf[0..ed.len]);
    ed.pos = prevChar(ed.buf[0..ed.len], ed.pos);
    try std.testing.expectEqual(@as(usize, 3), ed.pos); // before the CJK char
}

test "charWidth basics" {
    try std.testing.expectEqual(@as(usize, 1), charWidth('a'));
    try std.testing.expectEqual(@as(usize, 2), charWidth(0xE4)); // CJK lead
    try std.testing.expectEqual(@as(usize, 0), charWidth(0xB8)); // continuation
}

test "snapBack is safe at buffer end and lands on char starts" {
    const buf = "ab\xe4\xb8\xad"; // 'a','b','中'
    try std.testing.expectEqual(@as(usize, 5), snapBack(buf, buf.len)); // end is a boundary
    try std.testing.expectEqual(@as(usize, 2), snapBack(buf, 4)); // mid-中 -> start
    try std.testing.expectEqual(@as(usize, 2), snapBack(buf, 3));
    try std.testing.expectEqual(@as(usize, 0), snapBack(buf, 0));
    // Regression: pos == buf.len must not read buf[pos].
    try std.testing.expectEqual(@as(usize, 5), snapBack(buf, 99)); // clamped
}

test "loadHistory truncates on a char boundary (fixed buffer)" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var buf: [4]u8 = undefined; // smaller than the entry below
    var ed = Editor{ .w = &aw.writer, .file_writer = undefined, .r = undefined, .prompt = ">", .buf = &buf };
    ed.loadHistory("中中"); // 6 bytes into 4 — truncated at 4 (lead of 2nd 中)
    try std.testing.expectEqual(@as(usize, 4), ed.len);
    // Park at end: byte 3 is a lead byte, pos stays (nothing better exists).
    try std.testing.expectEqual(@as(usize, 4), ed.pos);
}

test "classifyCsi maps keys and keyboard protocols" {
    try std.testing.expect(classifyCsi("A") == .up);
    try std.testing.expect(classifyCsi("B") == .down);
    try std.testing.expect(classifyCsi("C") == .right);
    try std.testing.expect(classifyCsi("D") == .left);
    try std.testing.expect(classifyCsi("H") == .home);
    try std.testing.expect(classifyCsi("1~") == .home);
    try std.testing.expect(classifyCsi("4~") == .end);
    try std.testing.expect(classifyCsi("3~") == .delete);
    try std.testing.expect(classifyCsi("200~") == .paste_start);
    // Shift+Enter (13;2u) and Ctrl+Enter (13;5u) insert newlines.
    try std.testing.expect(classifyCsi("13;2u") == .newline);
    try std.testing.expect(classifyCsi("13;5u") == .newline);
    // Unknown sequences (mouse, focus, …) must not leak as text.
    try std.testing.expect(classifyCsi("0;10;5M") == .ignore);
    try std.testing.expect(classifyCsi("I") == .ignore);
}

test "lineOf and moveVertically navigate multi-line buffers" {
    const buf = "ab\ncdef\nghi";
    // Cursor at end of "cdef" (pos 7): line span is 3..7.
    try std.testing.expectEqual(LineSpan{ .start = 3, .end = 7 }, lineOf(buf, 7));
    // Up keeps the column, clamped to the shorter line above.
    try std.testing.expectEqual(@as(usize, 2), moveVertically(buf, 7, -1).?); // col 4 -> clamp 2
    // Down from "ab" col 2 -> same column on "cdef" (pos 5, after "cd").
    try std.testing.expectEqual(@as(usize, 5), moveVertically(buf, 2, 1).?);
    // First line up / last line down: null (history fallback).
    try std.testing.expect(moveVertically(buf, 1, -1) == null);
    try std.testing.expect(moveVertically(buf, buf.len, 1) == null);
}

test "pasteNormalize converts CRLF and lone CR to LF" {
    var skip = false;
    try std.testing.expectEqual(@as(?u8, '\n'), pasteNormalize('\r', &skip));
    try std.testing.expectEqual(@as(?u8, null), pasteNormalize('\n', &skip)); // CR swallowed
    try std.testing.expectEqual(@as(?u8, 'x'), pasteNormalize('x', &skip));
    try std.testing.expectEqual(@as(?u8, '\n'), pasteNormalize('\n', &skip)); // bare LF kept
}
