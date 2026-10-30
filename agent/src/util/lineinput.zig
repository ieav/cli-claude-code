/// Raw-mode line editor for the REPL prompt: arrows move the cursor,
/// up/down walk input history, Backspace/Delete/Home/End work, UTF-8
/// advances per character. Multi-line input is supported Claude-Code-style:
///   - Enter submits; Ctrl+J, Option+Enter (ESC+CR/LF), Shift+Enter via
///     terminal keyboard protocols (CSI 13;2u), and a trailing `\`+Enter
///     all insert a newline.
///   - Bracketed paste (CSI 200~…201~) lands as ONE input with embedded
///     newlines (CRLF normalized).
///   - The WHOLE buffer renders (every logical line, soft-wrapped by
///     display width); huge inputs show a cursor-centered window with
///     ↟/↡ clipped-line counts. Rendering is block-based: the previous
///     paint's rows are cleared as a unit, so overwidth lines cannot
///     smear across the screen.
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

/// Echo caps for the committed input: a huge paste must not flood the
/// transcript — beyond these, the echo shows the head plus a dim marker.
const ECHO_CAP_LINES: usize = MAX_VIEW_ROWS;
const ECHO_CAP_BYTES: usize = 8192;

/// Re-render the committed input in the history color so the user's sent
/// message stays visible in the transcript (the typed block is erased on
/// submit — this echo IS what remains of it). Multi-line and wrapped
/// content echoes in full: it is one-shot output that is never cleared
/// again, so terminal wrapping is harmless here. Only huge inputs are
/// capped at ECHO_CAP_LINES / ECHO_CAP_BYTES with a "… 另有 N 行" marker.
fn renderCommitted(w: *std.Io.Writer, prompt: []const u8, line: []const u8) !void {
    if (line.len == 0) {
        try w.writeAll("\n");
        return;
    }
    const total_lines = std.mem.count(u8, line, "\n") + 1;
    var body = line;
    if (body.len > ECHO_CAP_BYTES) {
        var cut = ECHO_CAP_BYTES;
        while (cut > 0 and (body[cut] & 0xC0) == 0x80) cut -= 1; // char boundary
        body = body[0..cut];
    }
    try w.writeAll("\r\x1b[2K");
    try w.writeAll(prompt);
    try w.writeAll("\x1b[1;35m");
    var rest = body;
    var shown: usize = 0;
    while (rest.len > 0 and shown < ECHO_CAP_LINES) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (shown > 0) try w.writeAll("\n");
        try w.writeAll(rest[0..nl]);
        shown += 1;
        rest = if (nl < rest.len) rest[nl + 1 ..] else rest[nl..];
    }
    try w.writeAll("\x1b[0m");
    if (total_lines > shown or line.len > body.len) {
        var hidden = total_lines -| shown;
        if (line.len > body.len and hidden == 0) hidden = 1; // byte-cut mid-line
        try w.print("\n\x1b[2m… 另有 {d} 行\x1b[0m", .{hidden});
    }
    try w.writeAll("\n");
}

/// Terminal column count via TIOCGWINSZ; 80 as the conservative fallback.
fn termWidth() usize {
    var ws: std.c.winsize = undefined;
    if (std.c.ioctl(0, std.c.T.IOCGWINSZ, &ws) == 0 and ws.col > 0) return ws.col;
    return 80;
}

/// Test hook: nonzero overrides TIOCGWINSZ so renderer math is testable.
pub var force_width: usize = 0;

fn effWidth() usize {
    return if (force_width != 0) force_width else termWidth();
}

/// Physical rows the input block may occupy (prompt + wrapped lines). A
/// taller layout — a huge paste — shows a cursor-centered window instead:
/// repainting unbounded rows per keystroke would both flicker and scroll
/// the transcript out of view.
pub const MAX_VIEW_ROWS: usize = 16;

/// Upper bound on rows a single clear walks. last_rows is set by ourselves
/// (≤ MAX_VIEW_ROWS + edge rows), but a SIGWINCH between renders can shrink
/// the screen under an older, taller block — stays bounded regardless.
const CLEAR_ROW_CAP: usize = 32;

test "committed input echoes in full: magenta, multi-line, capped pastes" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try renderCommitted(&aw.writer, "> ", "hello");
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> \x1b[1;35mhello\x1b[0m\n") != null);

    var aw_cjk: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw_cjk.deinit();
    try renderCommitted(&aw_cjk.writer, "> ", "今天几号");
    try std.testing.expect(std.mem.indexOf(u8, aw_cjk.written(), "\x1b[1;35m今天几号\x1b[0m\n") != null);

    // Empty submit: nothing to show, bare newline as before.
    var aw3: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw3.deinit();
    try renderCommitted(&aw3.writer, "> ", "");
    try std.testing.expectEqualStrings("\n", aw3.written());

    // Multi-line echoes EVERY line (the typed block was erased on submit —
    // this echo is the only trace of the sent message).
    var aw4: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw4.deinit();
    try renderCommitted(&aw4.writer, "> ", "a\nb");
    try std.testing.expect(std.mem.indexOf(u8, aw4.written(), "> \x1b[1;35ma\nb\x1b[0m\n") != null);

    // Past the line cap: first ECHO_CAP_LINES lines + a dim "more" marker.
    var aw5: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw5.deinit();
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    for (0..20) |i| {
        if (i > 0) try big.append(std.testing.allocator, '\n');
        var lb: [10]u8 = undefined;
        const ls = try std.fmt.bufPrint(&lb, "line{d}", .{i + 1});
        try big.appendSlice(std.testing.allocator, ls);
    }
    try renderCommitted(&aw5.writer, "> ", big.items);
    const out5 = aw5.written();
    try std.testing.expect(std.mem.indexOf(u8, out5, "line16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out5, "line17") == null); // hidden
    try std.testing.expect(std.mem.indexOf(u8, out5, "… 另有 4 行") != null);

    // Past the byte cap: cut at a char boundary, marker shows hidden lines.
    var aw6: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw6.deinit();
    var huge_buf: [10000]u8 = undefined;
    var hl: usize = 0;
    while (hl + 3 <= huge_buf.len) : (hl += 3) @memcpy(huge_buf[hl..][0..3], "中");
    try renderCommitted(&aw6.writer, "> ", huge_buf[0..hl]);
    try std.testing.expect(std.mem.indexOf(u8, aw6.written(), "… 另有 ") != null);
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

/// ── Paste-fold (Claude-Code-style pills) ─────────────────────────────
///
/// A big paste does not balloon the input box: the buffer holds a 3-byte
/// unforgeable marker (NUL, slot digit, NUL) and the full content lives in
/// an Editor side slot. The renderer shows a one-line pill
/// ("[📄 粘贴 · N 行 · B]"); submit expands markers back to the full text.

/// Fold thresholds: a paste beyond EITHER becomes a pill. Small pastes
/// keep today's behavior (raw text in the buffer).
pub const PASTE_FOLD_LINES: usize = 8;
pub const PASTE_FOLD_BYTES: usize = 1024;

/// Simultaneous pills per prompt; a further big paste lands raw.
pub const PASTE_SLOTS: usize = 4;

/// What a folded paste remembers for display and expansion.
const PasteSlot = struct {
    data: []u8, // allocator-owned; freed when readLine ends
    lines: usize,
};

fn pillText(stat: PasteStat, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "[📄 粘贴 · {d} 行 · {d}B]", .{ stat.lines, stat.bytes }) catch "[📄 粘贴]";
}

const PasteStat = struct { lines: usize, bytes: usize };

/// Marker bytes at buf[i]? Returns the marker length (3) or 0. A NUL can
/// be neither typed (c >= 0x20 filter) nor pasted (pasteSlice drops < 0x20
/// control bytes) — markers exist only where pasteBody put them.
fn markerLen(buf: []const u8, i: usize) usize {
    if (buf[i] == 0 and i + 2 < buf.len and
        buf[i + 1] >= '0' and buf[i + 1] < '0' + PASTE_SLOTS and buf[i + 2] == 0) return 3;
    return 0;
}

/// A marker occupies bytes [i-3, i).
fn markerEndsAt(buf: []const u8, i: usize) bool {
    return i >= 3 and markerLen(buf, i - 3) == 3;
}

/// Display width of one glyph (marker → its pill text width).
fn glyphWidth(buf: []const u8, i: usize, pills: []const ?PasteStat) usize {
    if (markerLen(buf, i) == 3) {
        const slot = buf[i + 1] - '0';
        var tb: [48]u8 = undefined;
        const stat = pills[slot] orelse PasteStat{ .lines = 0, .bytes = 0 };
        return strWidth(pillText(stat, &tb));
    }
    return strWidth(buf[i..nextChar(buf, i)]);
}

/// Step one display unit forward (marker is atomic, like one wide char).
fn nextGlyph(buf: []const u8, i: usize) usize {
    if (markerLen(buf, i) == 3) return i + 3;
    return nextChar(buf, i);
}

/// Step one display unit back (marker is atomic).
fn prevGlyph(buf: []const u8, i: usize) usize {
    if (markerEndsAt(buf, i)) return i - 3;
    return prevChar(buf, i);
}

/// The marker bytes for a slot, as a slice into a 3-byte buffer.
fn markerBytes(slot: usize, buf: *[3]u8) []const u8 {
    buf[0] = 0;
    buf[1] = @intCast('0' + slot);
    buf[2] = 0;
    return buf;
}

/// Expand every marker in `line` using `pills`; allocator-owned result.
/// Returns null when `line` contains no marker (caller keeps the original).
fn expandPasted(alloc: std.mem.Allocator, line: []const u8, data_of: []const ?PasteSlot) !?[]u8 {
    if (std.mem.indexOfScalar(u8, line, 0) == null) return null;
    var total = line.len;
    var i: usize = 0;
    while (i < line.len) {
        if (markerLen(line, i) == 3) {
            const slot = line[i + 1] - '0';
            total -= 3;
            if (data_of[slot]) |d| total += d.data.len;
            i += 3;
        } else i += 1;
    }
    const out = try alloc.alloc(u8, total);
    var w: usize = 0;
    i = 0;
    while (i < line.len) {
        if (markerLen(line, i) == 3) {
            const slot = line[i + 1] - '0';
            if (data_of[slot]) |d| {
                @memcpy(out[w..][0..d.data.len], d.data);
                w += d.data.len;
            }
            i += 3;
        } else {
            out[w] = line[i];
            w += 1;
            i += 1;
        }
    }
    return out[0..w];
}

/// One soft-wrap scan of a logical line: the physical rows it occupies at
/// `first_avail` (row-0 budget: terminal width minus the prompt) then
/// `avail` per continuation row, and the (row, col) cell where `cursor`
/// (a byte offset) sits. Wide chars never split across rows: a char that
/// does not fit starts the next row; a char wider than a fresh row is
/// forced in (col > 0 guard) so progress never stalls. Paste markers count
/// as one glyph of their pill's display width.
const LineScan = struct { rows: usize, cursor_row: usize, cursor_col: usize };

fn scanLine(seg: []const u8, first_avail: usize, avail: usize, cursor: usize, pills: []const ?PasteStat) LineScan {
    var rows: usize = 1;
    var budget = first_avail;
    var col: usize = 0;
    var cur_row: usize = 0;
    var cur_col: usize = 0;
    var cur_seen = false;
    var i: usize = 0;
    while (i < seg.len) {
        const next = nextGlyph(seg, i);
        const cw = glyphWidth(seg, i, pills);
        if (col > 0 and col + cw > budget) {
            rows += 1;
            col = 0;
            budget = avail;
        }
        if (!cur_seen and cursor <= i) {
            cur_seen = true;
            cur_row = rows - 1;
            cur_col = col;
        }
        col += cw;
        i = next;
    }
    if (!cur_seen) {
        cur_row = rows - 1;
        cur_col = col;
    }
    return .{ .rows = rows, .cursor_row = cur_row, .cursor_col = cur_col };
}

/// Write `s` clipped to `budget` display columns, "…" when cut. Single-row
/// UI (the reverse-search line) must never autowrap — that is exactly how
/// the overwidth-input explosion used to start.
fn writeClipped(w: *std.Io.Writer, s: []const u8, budget: usize, pills: []const ?PasteStat) !void {
    if (budget < 2) return;
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const is_marker = markerLen(s, i) == 3;
        const next = if (is_marker) i + 3 else nextChar(s, i);
        const cw = glyphWidth(s, i, pills);
        if (col + cw > budget - 1) {
            try w.writeAll("…");
            return;
        }
        if (is_marker) {
            const slot = s[i + 1] - '0';
            var tb: [48]u8 = undefined;
            const stat = pills[slot] orelse PasteStat{ .lines = 0, .bytes = 0 };
            try w.writeAll(pillText(stat, &tb));
        } else {
            try w.writeAll(s[i..next]);
        }
        col += cw;
        i = next;
    }
}

/// What a parsed CSI sequence asks the editor to do.
const CsiAction = enum { up, down, left, right, home, end, delete, newline, esc, ctrl, paste_start, ignore };

/// kitty disambiguate mode re-encodes ctrl+letter as CSI <codepoint>;5u
/// (ctrl+shift as ;6u). Reverse it to the C0 control byte the main key
/// switch already dispatches (97..122 → 0x01..0x1A). null when the
/// sequence is anything else.
fn ctrlLetterByte(seq: []const u8) ?u8 {
    const semi = std.mem.indexOfScalar(u8, seq, ';') orelse return null;
    const code = std.fmt.parseInt(u16, seq[0..semi], 10) catch return null;
    if (code < 97 or code > 122) return null;
    const mods = seq[semi + 1 ..];
    if (!std.mem.eql(u8, mods, "5u") and !std.mem.eql(u8, mods, "6u")) return null;
    return @intCast(code - 96);
}

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
    // Kitty keyboards (disambiguate mode) encode a bare Esc as CSI 27u —
    // map it so Esc keeps its recall semantics under the pushed protocol.
    if (seq.len >= 3 and std.mem.startsWith(u8, seq, "27") and seq[seq.len - 1] == 'u') return .esc;
    // Same mode re-encodes EVERY ctrl+letter as CSI <code>;5u — without
    // this mapping Ctrl-C/Ctrl-R/Ctrl-A… silently die on kitty terminals
    // (spec: "ctrl+c will no longer generate SIGINT, but instead be
    // delivered as a CSI u escape code").
    if (seq.len >= 4 and ctrlLetterByte(seq) != null) return .ctrl;
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
/// prompt by readLine. Same capacity as pending so a fully-typed
/// unsubmitted line never truncates on merge.
pub var typeahead_buf: [2048]u8 = undefined;
pub var typeahead_len: usize = 0;

/// ── P4: generation-period live input ─────────────────────────────────────
/// While the model streams, the stream callback's stdin poll feeds the
/// pending line below (live dim echo) instead of silently buffering.
/// Enter QUEUES the text as a message: the agent loop injects it between
/// tool rounds (the model sees it one round later — no interruption), and
/// anything still queued when the turn ends auto-submits as the next
/// message. Unsubmitted pending merges into typeahead at readLine entry.
pub var pending_buf: [2048]u8 = undefined;
pub var pending_len: usize = 0;
/// The dim echo line is currently drawn at the cursor (no \n yet).
pub var pending_shown: bool = false;
/// Stream-side cursor state: the stream callback syncs its at_line_start
/// here BEFORE the esc probe, so the pending echo knows whether the cursor
/// sits mid-output-line — redrawing with \r\x1b[2K there would EAT the
/// half-printed line. When mid-line, the echo first moves below it (\n).
pub var stream_at_line_start: bool = true;

pub const QUEUED_MAX: usize = 4;
pub const QUEUED_CAP: usize = 2048;
pub var queued_msgs: [QUEUED_MAX][QUEUED_CAP]u8 = undefined;
pub var queued_lens: [QUEUED_MAX]usize = @splat(0);
pub var queued_count: usize = 0;
/// Read cursor: slots below it are consumed. Slots are NOT shifted on
/// take — an eager shift used to overwrite the very slice being returned
/// (take #1 handed out slot 0's bytes AFTER copying message 2 into it).
/// Compaction happens only when the queue drains fully.
pub var queued_read: usize = 0;

/// True while unconsumed messages remain.
pub fn queuedHas() bool {
    return queued_read < queued_count;
}

/// Hand out the oldest unconsumed message. The slice stays valid until
/// the queue fully drains (compaction) — read or dupe it promptly.
pub fn queuedTake() ?[]const u8 {
    if (queued_read >= queued_count) {
        queued_count = 0;
        queued_read = 0;
        @memset(&queued_lens, 0);
        return null;
    }
    const out = queued_msgs[queued_read][0..queued_lens[queued_read]];
    queued_read += 1;
    return out;
}

/// Display-capped tail of the pending buffer, cut at a UTF-8 boundary.
fn pendingDisplay() []const u8 {
    const s = pending_buf[0..pending_len];
    // ~60 display cols from the tail (newest keystrokes stay visible)
    var i = s.len;
    var cols: usize = 0;
    while (i > 0) {
        // walk back one rune
        var start = i - 1;
        while (start > 0 and (s[start] & 0xC0) == 0x80) start -= 1;
        const rune_cols: usize = if (s[start] >= 0xE0) 2 else 1;
        if (cols + rune_cols > 60) break;
        cols += rune_cols;
        i = start;
    }
    return s[i..];
}

/// (Re)draw the dim pending-input echo line at the cursor. Single line,
/// display-capped — safe for \r + clear-line redraw. When the stream
/// cursor is mid-output-line, first drop below it (\n) instead of wiping.
pub fn renderPendingLine(w: *std.Io.Writer) void {
    if (pending_len == 0) {
        if (pending_shown) {
            std.Io.Writer.writeAll(w, "\r\x1b[2K") catch {};
        }
        pending_shown = false;
        return;
    }
    if (!stream_at_line_start) {
        std.Io.Writer.writeAll(w, "\n") catch {};
        stream_at_line_start = true;
    }
    std.Io.Writer.print(w, "\r\x1b[2K\x1b[2m⌨ {s}\x1b[0m", .{pendingDisplay()}) catch {};
    pending_shown = true;
}

/// Seal the echo line before stream output prints: freeze it into
/// scrollback with a newline so output flows BELOW it (chat-app style).
/// The pending buffer itself survives and redraws on the next keystroke.
pub fn pendingSealLine(w: *std.Io.Writer) void {
    if (pending_shown) {
        std.Io.Writer.writeAll(w, "\n") catch {};
        pending_shown = false;
    }
}

fn pendingAppend(c: u8, w: ?*std.Io.Writer) void {
    if (pending_len >= pending_buf.len) return; // hard cap, drop silently
    pending_buf[pending_len] = c;
    pending_len += 1;
    if (w) |ww| renderPendingLine(ww);
}

fn pendingBackspace(w: ?*std.Io.Writer) void {
    if (pending_len == 0) return;
    pending_len -= 1;
    while (pending_len > 0 and (pending_buf[pending_len] & 0xC0) == 0x80) pending_len -= 1;
    if (w) |ww| renderPendingLine(ww);
}

/// Enter pressed during generation: queue the pending text as a message
/// (mid-turn injection / auto-send at turn end). Returns true when a
/// message was queued.
fn pendingSubmit(w: ?*std.Io.Writer) bool {
    if (pending_len == 0) return false;
    if (queued_count >= QUEUED_MAX) return false;
    @memcpy(queued_msgs[queued_count][0..pending_len], pending_buf[0..pending_len]);
    queued_lens[queued_count] = pending_len;
    queued_count += 1;
    pending_len = 0;
    if (w) |ww| {
        if (!stream_at_line_start) {
            std.Io.Writer.writeAll(ww, "\n") catch {};
            stream_at_line_start = true;
        }
        pendingSealLine(ww);
        std.Io.Writer.writeAll(ww, "  \x1b[2m↳ 已排队（本轮生效或回合后自动发送）\x1b[0m\n") catch {};
    }
    return true;
}

/// Merge unsubmitted pending into typeahead (readLine entry) — the old
/// behavior (bytes survive into the editor) is preserved for text typed
/// without Enter.
pub fn pendingMergeIntoTypeahead() void {
    var i: usize = 0;
    while (i < pending_len and typeahead_len < typeahead_buf.len) : (i += 1) {
        typeahead_buf[typeahead_len] = pending_buf[i];
        typeahead_len += 1;
    }
    pending_len = 0;
    pending_shown = false;
    // Resync: a paste whose stream ended before the terminator would
    // otherwise keep the probe swallowing prompt bytes as paste content.
    paste_active = false;
}

/// Non-blocking Esc probe for the streaming callback: true when the user
/// pressed Esc (a following CSI sequence is swallowed so arrow keys don't
/// leak into the prompt). Other bytes feed the P4 live pending line:
/// printable/CR-LF echo live, Backspace edits, CR queues the message.
/// `w` is null in drain contexts (post-cancel) — capture without echo.
/// Checks the reader's OWN buffer first — a burst "text…ESC" lands in one
/// read and the kernel fd goes dry, so polling fd alone never sees the Esc
/// (same trap menu.readKey fixed with its bufferedLen check).
/// Bracketed-paste state for the generation-period input path: a paste
/// during streaming feeds pending as CONTENT (CR → newline, never submit)
/// instead of cancelling the generation the way a bare Esc/CSI does.
pub var paste_active: bool = false;

/// What a captured ESC-following sequence means.
const EscSeq = enum { cancel, paste_start, paste_end };

fn classifyEscSeq(seq: []const u8) EscSeq {
    if (std.mem.eql(u8, seq, "[200~")) return .paste_start;
    if (std.mem.eql(u8, seq, "[201~")) return .paste_end;
    return .cancel;
}

pub fn escProbe(r: *std.Io.Reader, w: ?*std.Io.Writer) bool {
    // Drain ALL pending bytes per invocation: the old take-one-byte-per-
    // call shape capped live input at ~20 bytes/s (one byte per 50ms
    // throttle window) — a typed supplement outlived the stream and its
    // Enter leaked into the next prompt.
    while (true) {
        if (r.bufferedLen() == 0) {
            var pfd = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&pfd, 1, 0) != 1 or (pfd[0].revents & std.c.POLL.IN) == 0) return false;
        }
        const esc = escProbeOne(r, w);
        if (esc) return true;
    }
}

/// Capture the bytes following an ESC promptly (5ms per byte, `~`-styles
/// are 4-5 long). Returns the captured sequence WITHOUT the ESC. Checks
/// the reader's OWN buffer before polling the fd — a burst "ESC[200~…"
/// lands in ONE read and the kernel fd goes dry, so a poll-only loop
/// would see an empty sequence and misclassify (the escProbe drain trap).
fn captureEscSeq(r: *std.Io.Reader) [8]u8 {
    var seq: [8]u8 = @splat(0);
    var n: usize = 0;
    while (n < seq.len) {
        if (r.bufferedLen() == 0) {
            var p2 = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&p2, 1, 5) != 1 or (p2[0].revents & std.c.POLL.IN) == 0) break;
        }
        const b = r.takeByte() catch break;
        seq[n] = b;
        n += 1;
        // '[' sits INSIDE the final-byte range — only a byte AFTER the
        // introducer (or any non-'[' first byte) in 0x40..0x7E ends it.
        if (n >= 2 and b >= 0x40 and b <= 0x7E) break;
        if (n == 1 and b != '[') break; // lone Esc — no sequence follows
    }
    return seq;
}

fn escProbeOne(r: *std.Io.Reader, w: ?*std.Io.Writer) bool {
    const c = r.takeByte() catch return false;
    if (paste_active) {
        if (c == 0x1b) {
            const seq = captureEscSeq(r);
            if (classifyEscSeq(std.mem.sliceTo(&seq, 0)) == .paste_end) {
                paste_active = false;
                if (w) |ww| renderPendingLine(ww);
                return false;
            }
            // ESC inside pasted text: keep it as content (plus whatever
            // sequence bytes were captured).
            pendingAppend(0x1b, w);
            for (seq) |b| {
                if (b == 0) break;
                pendingAppend(b, w);
            }
            return false;
        }
        // Paste content: CR becomes a newline (a pasted multi-line blob is
        // ONE message, never N submits); other control bytes drop.
        if (c == '\r') {
            pendingAppend('\n', w);
        } else if (c >= 0x20 or c == '\n' or c == '\t') {
            pendingAppend(c, w);
        }
        return false;
    }
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
        if (c == '\r') {
            _ = pendingSubmit(w);
        } else if (c == 0x7f) {
            pendingBackspace(w);
        } else if (c >= 0x20 or c == '\n') {
            pendingAppend(c, w);
        }
        return false;
    }
    // ESC: classify the sequence. Paste markers feed pending; anything
    // else (arrow keys, plain Esc) cancels the generation, as before.
    // sliceTo(0): the capture array is fixed-length zero-padded — comparing
    // the whole [8]u8 never matched and every paste fell through to cancel.
    const seq = captureEscSeq(r);
    switch (classifyEscSeq(std.mem.sliceTo(&seq, 0))) {
        .paste_start => {
            paste_active = true;
            return false;
        },
        .paste_end => return false, // stray end marker: swallow
        .cancel => return true,
    }
}

/// Streaming painter for the input block's content rows: walks soft-wrapped
/// rows of each logical line, writing only rows in [top, bot) of the
/// content-row space. `gr` is the CURRENT content row; `painted` counts
/// the rows that actually hit the terminal.
const BlockPainter = struct {
    w: *std.Io.Writer,
    top: usize,
    bot: usize,
    gr: usize = 0,
    painted: usize = 0,
    row_open: bool = false, // a visible row is under the cursor

    fn openRow(self: *BlockPainter) !void {
        if (self.gr < self.top or self.gr >= self.bot) return; // clipped
        if (self.row_open) try self.w.writeAll("\r\n");
        self.row_open = true;
        self.painted += 1;
    }
};

const StyleKind = enum { none, cyan, gray, mag };

/// SGR state shared across the block's lines: what is currently emitted,
/// plus the per-render styling decisions (browsing magenta, slash-command
/// token colors, whether the prompt shares content row 0).
const StyleState = struct {
    cur: StyleKind = .none,
    browse: bool = false,
    is_first: bool = false, // painting line 0 of the buffer
    slash_tok: usize = 0, // cyan/gray up to this byte on line 0
    slash_known: bool = false,
    allow_prompt: bool = false,
};

/// Non-blocking CSI pickup after an ESC that a context cannot follow with
/// the blocking seq2 read (search mode): kitty terminals deliver Esc as
/// one burst ESC[27u, so the body is already buffered — swallow it (with
/// a 5 ms grace for split reads) instead of leaking "[27u" as text. A
/// lone legacy Esc (nothing promptly following) returns null. The one
/// byte taken while probing is NOT pushback-able: '\r' (alt+enter) is
/// reported so the caller can handle it; anything else is dropped.
fn tryTakeCsi(r: *std.Io.Reader, body: *[16]u8) ?struct { seq: []const u8, alt_enter: bool } {
    if (r.bufferedLen() == 0) {
        var pfd = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&pfd, 1, 5) != 1 or (pfd[0].revents & std.c.POLL.IN) == 0) return null;
    }
    const c = r.takeByte() catch return null;
    if (c != '[') {
        if (c == '\r') return .{ .seq = "", .alt_enter = true };
        return .{ .seq = "", .alt_enter = false }; // rare alt+letter: dropped
    }
    var n: usize = 0;
    while (n < body.len) {
        if (r.bufferedLen() == 0) {
            var pfd = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&pfd, 1, 5) != 1 or (pfd[0].revents & std.c.POLL.IN) == 0) break;
        }
        const b = r.takeByte() catch break;
        body[n] = b;
        n += 1;
        if ((b >= 0x40 and b <= 0x7E) and b != ';') break; // final byte
    }
    if (n == 0) return null;
    return .{ .seq = body[0..n], .alt_enter = false };
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
    /// Rows occupied by the last painted block and the block-relative row
    /// the cursor is parked on. The next render clears exactly that region
    /// before repainting. Anything that prints OUTSIDE render() (the
    /// reverse-search line, Ctrl-C status text) must reset both to 0 so
    /// the next render starts fresh instead of clearing at a stale anchor.
    last_rows: usize = 0,
    park_row: usize = 0,
    /// Byte re-injected by the CSI handler (kitty ctrl+letter → C0): the
    /// main loop picks it up as the next key press so every existing
    /// binding runs through its ORIGINAL dispatch path — no logic forks.
    injected: ?u8 = null,
    /// Folded-paste side slots: full content behind each buffer marker.
    /// data is grow-allocator owned; readLine frees them on every exit.
    pastes: [PASTE_SLOTS]?PasteSlot = @splat(null),

    fn pasteStats(self: *const Editor) [PASTE_SLOTS]?PasteStat {
        var st: [PASTE_SLOTS]?PasteStat = @splat(null);
        for (self.pastes, 0..) |p, i| {
            if (p) |d| st[i] = .{ .lines = d.lines, .bytes = d.data.len };
        }
        return st;
    }

    /// Erase the previously painted block: lift the cursor back to the
    /// block's top-left (park_row rows up), clear every row it occupied
    /// (CUD, never \n — clearing must not scroll), and leave the cursor at
    /// the block's top row. Resets last_rows/park_row to 0.
    fn clearBlock(self: *Editor) !void {
        try self.csi1("\x1b[{d}A", self.park_row);
        const n = @min(self.last_rows, CLEAR_ROW_CAP);
        if (n > 0) {
            try self.w.writeAll("\r\x1b[2K");
            var i: usize = 1;
            while (i < n) : (i += 1) try self.w.writeAll("\x1b[B\r\x1b[2K");
            try self.csi1("\x1b[{d}A", n - 1);
        }
        self.last_rows = 0;
        self.park_row = 0;
    }

    /// Emit a one-parameter CSI (cursor up/down/right) when n > 0.
    fn csi1(self: *Editor, comptime fmt: []const u8, n: usize) !void {
        if (n == 0) return;
        var b: [16]u8 = undefined;
        const seq = std.fmt.bufPrint(&b, fmt, .{n}) catch return;
        try self.w.writeAll(seq);
    }

    /// Paint the input block: prompt + every windowed logical line,
    /// soft-wrapped at the terminal width. Overwidth lines wrap onto
    /// several physical rows — the block-aware clear makes that safe, which
    /// the old single-row `\r\x1b[2K` repaint was not (each keystroke on an
    /// overwidth line used to smear one more full copy onto the screen).
    /// Huge buffers window around the cursor with ↟/↡ clipped counts.
    fn render(self: *Editor) !void {
        const term_w = @max(effWidth(), 8);
        const had_block = self.last_rows > 0;
        try self.clearBlock();
        if (!had_block) try self.w.writeAll("\r\x1b[2K");

        const line = self.buf[0..self.len];
        const prompt_w = strWidth(self.prompt);
        const first_avail = if (term_w > prompt_w) term_w - prompt_w else 1;

        // ── Census: total logical lines, the cursor's line, offset in it.
        const total_lines = std.mem.count(u8, line, "\n") + 1;
        var line_start: usize = 0;
        var cur_line: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, line_start, '\n')) |nl| {
            if (self.pos > nl) {
                cur_line += 1;
                line_start = nl + 1;
            } else break;
        }

        // ── Logical-line window: all lines, or a window around the cursor.
        //    The window is MAX-2 lines so the ↟/↡ edge rows still fit the
        //    block cap.
        const row_budget = MAX_VIEW_ROWS - 2;
        var spans: [MAX_VIEW_ROWS]LineSpan = undefined;
        var nspans: usize = 0;
        var clip_above: usize = 0;
        var clip_below: usize = 0;
        {
            var first: usize = 0;
            var last: usize = total_lines; // exclusive
            if (total_lines > row_budget) {
                const half = row_budget / 2;
                first = cur_line -| half;
                last = @min(first + row_budget, total_lines);
                first = last - row_budget;
            }
            clip_above = first;
            clip_below = total_lines - last;
            var s: usize = 0;
            var li: usize = 0;
            while (li < last and s <= line.len) : (li += 1) {
                const e = std.mem.indexOfScalarPos(u8, line, s, '\n') orelse line.len;
                if (li >= first) {
                    spans[nspans] = .{ .start = s, .end = e };
                    nspans += 1;
                }
                s = if (e < line.len) e + 1 else line.len;
            }
        }

        // ── Row scan of the windowed lines: rows per line, the cursor's
        //    content-row and column. Paste markers count as one glyph of
        //    their pill's width (a folded paste never balloons the block).
        const pills = self.pasteStats();
        var total_line_rows: usize = 0;
        var cur_gr: usize = 0;
        var cur_col: usize = 0;
        for (spans[0..nspans]) |sp| {
            const is_line0 = sp.start == 0;
            const fa = if (is_line0) first_avail else term_w;
            const sc = if (sp.start == line_start)
                scanLine(line[sp.start..sp.end], fa, term_w, self.pos - sp.start, &pills)
            else
                scanLine(line[sp.start..sp.end], fa, term_w, 0, &pills);
            if (sp.start == line_start) {
                cur_gr = total_line_rows + sc.cursor_row;
                cur_col = sc.cursor_col;
            }
            total_line_rows += sc.rows;
        }

        // ── Physical-row window: cap the block height, cursor centered.
        //    Same budget as the line window: edges + content ≤ MAX.
        var row_top: usize = 0;
        var row_bot: usize = total_line_rows;
        if (total_line_rows > row_budget) {
            row_top = cur_gr -| (row_budget / 2);
            row_top = @min(row_top, total_line_rows - row_budget);
            row_bot = row_top + row_budget;
        }
        const edge_top = clip_above > 0 or row_top > 0;
        const edge_bot = clip_below > 0 or row_bot < total_line_rows;

        // Slash-command highlight state (line 0, fresh drafts only).
        var st = StyleState{ .browse = self.browsing, .allow_prompt = row_top == 0 and clip_above == 0 };
        if (!self.browsing and line.len > 0 and line[0] == '/') {
            const l0_len = std.mem.indexOfScalar(u8, line, '\n') orelse line.len;
            const tok_end = std.mem.indexOfScalar(u8, line[0..l0_len], ' ') orelse l0_len;
            st.slash_tok = tok_end;
            st.slash_known = lineinput_cmds.isKnownCommand(line[0..tok_end]);
        }

        // ── Paint: top edge row, content rows through the walker, bottom
        //    edge row. Color transitions fire at emit time only, so rows
        //    clipped out of the window never leak SGR codes.
        var p = BlockPainter{ .w = self.w, .top = row_top, .bot = row_bot };
        var prompt_done = false;
        if (edge_top) {
            if (clip_above > 0) {
                try self.w.print("\x1b[2m↟ +{d} 行\x1b[0m", .{clip_above});
            } else {
                try self.w.writeAll("\x1b[2m…\x1b[0m");
            }
            p.row_open = true; // content starts on the NEXT row
        }
        for (spans[0..nspans]) |sp| {
            const is_line0 = sp.start == 0;
            st.is_first = is_line0;
            try self.emitLineP(&p, line[sp.start..sp.end], if (is_line0) first_avail else term_w, term_w, &prompt_done, &st);
        }
        if (edge_bot and p.row_open) {
            try self.w.writeAll("\r\n");
            if (clip_below > 0) {
                try self.w.print("\x1b[2m↡ +{d} 行\x1b[0m", .{clip_below});
            } else {
                try self.w.writeAll("\x1b[2m…\x1b[0m");
            }
        }
        if (st.cur != .none) try self.w.writeAll("\x1b[0m");

        // ── Park the cursor at its cell; record the block shape.
        var rows_total = p.painted + @as(usize, if (edge_top) 1 else 0) + @as(usize, if (edge_bot and p.row_open) 1 else 0);
        if (rows_total == 0) rows_total = 1; // degenerate: keep an anchor row
        self.last_rows = rows_total;
        var tr = cur_gr -| row_top;
        if (edge_top) tr += 1;
        if (tr >= rows_total) tr = rows_total - 1;
        self.park_row = tr;
        var tc = cur_col;
        if (cur_gr == 0 and st.allow_prompt) tc += prompt_w; // row 0 shares with the prompt
        tc = @min(tc, term_w - 1);
        try self.w.writeAll("\r");
        try self.csi1("\x1b[{d}A", rows_total - 1 - tr);
        try self.csi1("\x1b[{d}C", tc);
        try std.Io.File.Writer.flush(self.file_writer);
    }

    /// Paint one logical line soft-wrapped through `p`. `first_avail` is
    /// row 0's budget (line 0 shares its first row with the prompt); every
    /// continuation row gets `avail`. Wide chars never split: one that
    /// doesn't fit starts the next row, and one wider than a fresh row is
    /// forced in so the walk always advances.
    fn emitLineP(
        self: *Editor,
        p: *BlockPainter,
        seg: []const u8,
        first_avail: usize,
        avail: usize,
        prompt_done: *bool,
        st: *StyleState,
    ) !void {
        var budget = first_avail;
        var col: usize = 0;
        var i: usize = 0;
        var started = false;
        const pills = self.pasteStats();
        while (i < seg.len) {
            const is_marker = markerLen(seg, i) == 3;
            const next = if (is_marker) i + 3 else nextChar(seg, i);
            const cw = glyphWidth(seg, i, &pills);
            if (!started or (col > 0 and col + cw > budget)) {
                if (started) {
                    p.gr += 1;
                    col = 0;
                    budget = avail;
                }
                started = true;
                try p.openRow();
                if (!prompt_done.*) {
                    prompt_done.* = true;
                    if (p.row_open and st.allow_prompt and p.gr == 0) try self.w.writeAll(self.prompt);
                }
            }
            if (p.row_open) {
                if (is_marker) {
                    // A folded paste renders as its pill — never raw NULs.
                    // The pill carries its own dim style; the surrounding
                    // style state re-transitions on the next glyph.
                    const slot = seg[i + 1] - '0';
                    var tb: [48]u8 = undefined;
                    const stat = pills[slot] orelse PasteStat{ .lines = 0, .bytes = 0 };
                    if (st.cur != .none) try self.w.writeAll("\x1b[0m");
                    st.cur = .none;
                    try self.w.writeAll("\x1b[36m");
                    try self.w.writeAll(pillText(stat, &tb));
                    try self.w.writeAll("\x1b[0m");
                } else {
                    const desired: StyleKind = if (st.browse)
                        .mag
                    else if (st.is_first and i < st.slash_tok)
                        (if (st.slash_known) .cyan else .gray)
                    else
                        .none;
                    if (desired != st.cur) {
                        if (st.cur != .none) try self.w.writeAll("\x1b[0m");
                        switch (desired) {
                            .cyan => try self.w.writeAll("\x1b[36m"),
                            .gray => try self.w.writeAll("\x1b[90m"),
                            .mag => try self.w.writeAll("\x1b[1;35m"),
                            .none => {},
                        }
                        st.cur = desired;
                    }
                    try self.w.writeAll(seg[i..next]);
                }
            }
            col += cw;
            i = next;
        }
        if (!started) {
            // Empty line: still one (blank) physical row; the prompt may
            // land here on an empty buffer.
            try p.openRow();
            if (!prompt_done.*) {
                prompt_done.* = true;
                if (p.row_open and st.allow_prompt and p.gr == 0) try self.w.writeAll(self.prompt);
            }
        }
        p.gr += 1;
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
        // A paste pill deletes atomically (marker = 3 bytes, one unit).
        const start = prevGlyph(self.buf[0..self.len], self.pos);
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
        const end = nextGlyph(self.buf[0..self.len], self.pos);
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

    /// Stream the bracketed-paste body until the 201~ terminator (matched
    /// byte-by-byte so a lone ESC inside the content survives), normalizing
    /// CRLF. Over-cap bytes are dropped, not fatal. BIG pastes (beyond
    /// PASTE_FOLD_LINES or PASTE_FOLD_BYTES) fold into a one-line pill: the
    /// buffer keeps a 3-byte marker, the content an Editor side slot, and
    /// submit expands it back — the model receives the exact same bytes an
    /// unfolded paste would have produced.
    fn pasteBody(self: *Editor) !void {
        const term = "\x1b[201~";
        const g = self.grow orelse {
            // No grower (fixed-buffer tests): stream raw, fold unavailable.
            var mi0: usize = 0;
            try self.pasteStreamRaw(term, &mi0);
            self.browsing = false;
            return;
        };
        // Stage the whole paste on the heap FIRST — the fold decision needs
        // the full line count and size before touching the editor buffer.
        var staged: []u8 = g.alloc(u8, 4096) catch {
            var mi0: usize = 0;
            try self.pasteStreamRaw(term, &mi0);
            self.browsing = false;
            return;
        };
        var staged_is_slot = false; // freed by the Editor, not this defer
        defer if (!staged_is_slot) g.free(staged);
        var slen: usize = 0;
        var plines: usize = 1;
        var skip_lf = false;
        var mi: usize = 0; // partial terminator match length
        while (mi < term.len) {
            const pc = self.r.takeByte() catch {
                // EOF mid-paste: a partially matched terminator was real
                // content (e.g. a trailing lone ESC), not the marker.
                if (mi > 0) slen = try stageBytes(g, &staged, slen, term[0..mi], &plines, &skip_lf);
                break;
            };
            if (pc == term[mi]) {
                mi += 1;
                continue;
            }
            if (mi > 0) {
                slen = try stageBytes(g, &staged, slen, term[0..mi], &plines, &skip_lf);
                mi = 0;
            }
            if (pc == term[0]) {
                mi = 1;
                continue;
            }
            slen = try stageBytes(g, &staged, slen, &[1]u8{pc}, &plines, &skip_lf);
        }
        const body_len = slen;
        const big = plines > PASTE_FOLD_LINES or body_len > PASTE_FOLD_BYTES;
        if (big and body_len > 0) {
            var slot: ?usize = null;
            for (self.pastes, 0..) |p, i| {
                if (p == null) {
                    slot = i;
                    break;
                }
            }
            if (slot) |s| {
                // Shrink staging to the exact body; it becomes slot data.
                var data: []u8 = undefined;
                if (g.realloc(staged, body_len)) |exact| {
                    data = exact;
                    staged_is_slot = true;
                    staged = exact;
                } else |_| {
                    data = staged[0..body_len]; // shrink failed: keep block
                    staged_is_slot = true;
                }
                self.pastes[s] = .{ .data = data, .lines = plines };
                var m: [3]u8 = undefined;
                try self.insertBytes(markerBytes(s, &m));
                self.browsing = false;
                return;
            }
            // All slots taken: fall through, paste lands raw.
        }
        try self.insertBytes(staged[0..body_len]);
        self.browsing = false;
    }

    /// Fallback path (no grower): stream the paste straight into the
    /// buffer, same semantics as before folding existed.
    fn pasteStreamRaw(self: *Editor, term: []const u8, mi: *usize) !void {
        var skip_lf = false;
        while (mi.* < term.len) {
            const pc = self.r.takeByte() catch {
                if (mi.* > 0) try self.pasteSlice(term[0..mi.*], &skip_lf);
                break;
            };
            if (pc == term[mi.*]) {
                mi.* += 1;
                continue;
            }
            if (mi.* > 0) {
                try self.pasteSlice(term[0..mi.*], &skip_lf);
                mi.* = 0;
            }
            if (pc == term[0]) {
                mi.* = 1;
                continue;
            }
            try self.pasteSlice(&[1]u8{pc}, &skip_lf);
        }
    }

    /// Stage normalized bytes (CRLF→LF; control bytes except tab dropped —
    /// the same rules as pasteSlice) into a growing buffer, counting lines.
    /// CRLF may split across calls, so skip_lf lives with the caller.
    fn stageBytes(g: std.mem.Allocator, staged: *[]u8, slen: usize, bytes: []const u8, plines: *usize, skip_lf: *bool) !usize {
        var n = slen;
        for (bytes) |pc| {
            const nb = pasteNormalize(pc, skip_lf) orelse continue;
            if (nb < 0x20 and nb != '\t' and nb != '\n') continue;
            if (n >= staged.len) {
                if (staged.len >= INPUT_CAP) return n; // cap: drop the tail
                const grown = g.realloc(staged.*, @min(staged.len * 2, INPUT_CAP)) catch return n;
                staged.* = grown;
            }
            if (nb == '\n') plines.* += 1;
            staged.*[n] = nb;
            n += 1;
        }
        return n;
    }

    fn pasteSlice(self: *Editor, bytes: []const u8, skip_lf: *bool) !void {
        for (bytes) |pc| {
            const nb = pasteNormalize(pc, skip_lf) orelse continue;
            // Invisible control bytes (ESC, NUL, …) ride along in pasted
            // terminal output and would silently contaminate the message;
            // keep newline and tab only. ('\n' must be listed explicitly —
            // 0x0A < 0x20, and dropping it silently collapsed multi-line
            // pastes onto one line, contradicting the documented behavior.)
            if (nb < 0x20 and nb != '\t' and nb != '\n') continue;
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
    // 200~…201~ markers, and push the kitty keyboard "disambiguate" mode
    // so Shift+Enter arrives as CSI 13;2u (Esc as CSI 27u — handled below).
    // CAUTION: disambiguate ALSO re-encodes every ctrl+letter as
    // CSI <code>;5u (spec: "ctrl+c will no longer generate SIGINT") —
    // ctrlLetterByte maps those back to C0 so all ctrl bindings survive.
    // Enter, Backspace and unmodified arrows keep their legacy encodings.
    // Popped on every exit path so the terminal is left as found.
    try w.writeAll("\x1b[?2004h\x1b[>1u");
    try std.Io.File.Writer.flush(file_writer);
    defer {
        w.writeAll("\x1b[<u\x1b[?2004l") catch {};
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
    // Folded-paste side data dies with the editor (submit copies it out).
    defer for (&ed.pastes) |*ps| {
        if (ps.*) |d| alloc.free(d.data);
    };

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
    // P4: live-typed pending during generation (never submitted with
    // Enter) becomes the editor seed through the existing typeahead path.
    pendingMergeIntoTypeahead();
    if (typeahead_len > 0) {
        ed.insertBytes(typeahead_buf[0..typeahead_len]) catch {};
        typeahead_len = 0;
    }

    try ed.render();
    while (true) {
        // Kitty ctrl+letter arrives as CSI u and is mapped back to its C0
        // byte by the CSI handler — dispatch it through this same switch.
        const c = if (ed.injected) |b| blk: {
            ed.injected = null;
            break :blk b;
        } else ed.r.takeByte() catch return null;
        // Any other key breaks a pending double-Ctrl-C sequence. prev_cc
        // keeps the window alive across one CSI key event: the introducer
        // byte resets it here, and the .ctrl path (the SAME key press,
        // kitty-encoded) restores it before the C0 byte re-dispatches.
        const prev_cc = ctrl_c_at;
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
                    //
                    // kitty terminals send Esc as CSI 27u (and a repeated
                    // Ctrl+R as CSI 114;5u) — both arrive as one burst
                    // behind this ESC. Swallow the body and route it:
                    // repeated Ctrl+R pages older matches IN search; other
                    // sequences leave search; a lone legacy Esc (nothing
                    // following) leaves search as before. Without the
                    // swallow, "[27u" leaks into the buffer as text.
                    var csi: [16]u8 = undefined;
                    if (tryTakeCsi(ed.r, &csi)) |tk| {
                        if (tk.alt_enter) {
                            // ESC+CR = Option+Enter: leave search, newline.
                            search_on = false;
                            ed.insertBytes("\n") catch {};
                            try ed.render();
                            continue;
                        }
                        if (classifyCsi(tk.seq) == .ctrl) {
                            const b = ctrlLetterByte(tk.seq) orelse 0;
                            if (b == 0x12 and search_from > 0) {
                                search_from -= 1; // older match, STAY in search
                                // prong ends → the re-search/print block below runs
                            } else {
                                // Other ctrl keys: leave search, re-dispatch.
                                search_on = false;
                                ctrl_c_at = prev_cc; // same key press, keep the window
                                ed.injected = b;
                                continue;
                            }
                        }
                        if (classifyCsi(tk.seq) == .esc) {
                            // plain Esc (CSI 27u): leave search
                            search_on = false;
                            try ed.render();
                            continue;
                        }
                        // Arrows etc. during search: leave search (the
                        // sequence is already consumed).
                        search_on = false;
                        try ed.render();
                        continue;
                    }
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
                // Leave the painted block before drawing the search line —
                // it is a separate single row, and printing over a parked
                // block would strand the block state at a stale anchor.
                try ed.clearBlock();
                try ed.w.print("\r\x1b[2K(reverse-i-search)`{s}': ", .{search_q[0..search_ql]});
                if (search_failed and search_ql > 0) {
                    // (Empty query always matches the newest entry; red
                    // noise for it helped nobody.)
                    try ed.w.writeAll("\x1b[31m(failing)\x1b[0m");
                } else {
                    const span = lineOf(ed.buf[0..ed.len], @min(ed.pos, ed.len));
                    // Clip the match: a long hit must not autowrap the
                    // search row (same explosion class as overwidth input).
                    const budget = @max(@as(usize, 8), @as(usize, @max(effWidth(), 8)) -| (19 + search_ql));
                    try writeClipped(ed.w, ed.buf[span.start..span.end], budget, &ed.pasteStats());
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
                .esc => {
                    // CSI 27u = the Esc key on kitty keyboards. Same
                    // short-window recall of the just-sent message as a
                    // lone ESC byte; anything else just re-renders.
                    if (ed.len == 0 and recall_text != null and
                        util_time.nowMillis() - last_submit_ms < 5000)
                    {
                        ed.insertBytes(recall_text.?) catch {};
                        recall_text = null;
                    }
                },
                .ctrl => {
                    // kitty disambiguate: ctrl+letter → CSI <code>;5u.
                    // Reverse to the C0 byte and re-dispatch — the main
                    // switch keeps the single source of truth for every
                    // ctrl binding (double Ctrl-C exit, Ctrl-R search, …).
                    // Restore the double-Ctrl-C window the introducer byte
                    // reset above: this IS the Ctrl-C key press, not
                    // another key between two presses.
                    ctrl_c_at = prev_cc;
                    ed.injected = ctrlLetterByte(seq[0..sl]);
                    continue;
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
                    // Erase the painted block first (it may span many rows
                    // now) — the echo below prints at the freed top row and
                    // the cleared rows below are reused by the REPL output.
                    try ed.clearBlock();
                    // Folded pastes expand BEFORE anything downstream sees
                    // the line: echo, history and the returned slice all get
                    // the full content — the model receives exactly what an
                    // unfolded paste would have produced.
                    var exp: ?[]u8 = null;
                    // On any error below, the defer frees the expansion;
                    // on success it is returned (submitted guards it).
                    defer if (!submitted and exp != null) alloc.free(exp.?);
                    if (std.mem.indexOfScalar(u8, ed.buf[0..ed.len], 0) != null) {
                        exp = expandPasted(alloc, ed.buf[0..ed.len], &ed.pastes) catch null;
                    }
                    const line = exp orelse ed.buf[0..ed.len];
                    // Re-render the committed line in the history color so
                    // sent messages stay distinguishable in the transcript.
                    try renderCommitted(ed.w, ed.prompt, line);
                    try std.Io.File.Writer.flush(file_writer);
                    last_submit_ms = util_time.nowMillis();
                    recall_text = null; // submitted: recall window re-arms only via Esc interrupt
                    if (line.len > 0 and (history.items.len == 0 or !std.mem.eql(u8, history.items[history.items.len - 1], line))) {
                        const duped = alloc.dupe(u8, line) catch null;
                        if (duped) |o| {
                            history.append(alloc, o) catch alloc.free(o);
                        }
                    }
                    submitted = true;
                    if (exp) |e| {
                        // Expansion owns its buffer: hand it out directly.
                        alloc.free(ed.owned_buf.?);
                        return e;
                    }
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
                // The status text prints at the BLOCK top, not at the parked
                // cursor cell (mid-block splices into painted content).
                try ed.clearBlock();
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
                // Status text moved the cursor out of the block — drop the
                // block state so the next render starts on this fresh row.
                ed.last_rows = 0;
                ed.park_row = 0;
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
            0x02 => { // Ctrl-B: back one display unit (pill = one unit)
                if (ed.pos > 0) ed.pos = prevGlyph(ed.buf[0..ed.len], ed.pos);
            },
            0x06 => { // Ctrl-F: forward one display unit (pill = one unit)
                if (ed.pos < ed.len) ed.pos = nextGlyph(ed.buf[0..ed.len], ed.pos);
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
                    // UTF-8 coalescing: one key press arrives as one read
                    // burst, so a CJK char's continuation bytes are already
                    // buffered — insert them before the repaint instead of
                    // rendering a torn partial char 2-3 times per keystroke.
                    // A non-continuation byte re-dispatches via `injected`.
                    if (c >= 0xC0) {
                        while (ed.r.bufferedLen() > 0) {
                            const cb = ed.r.takeByte() catch break;
                            if ((cb & 0xC0) != 0x80) {
                                ed.injected = cb;
                                break;
                            }
                            try ed.insert(cb);
                        }
                    }
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

test "scanLine wraps by display width and locates the cursor cell" {
    // 20 CJK chars (width 2 each), budget 10 cols: 5 chars per row → 4 rows.
    const seg = "一二三四五六七八九十甲乙丙丁戊己庚辛壬癸";
    var none: [PASTE_SLOTS]?PasteStat = @splat(null);
    const sc = scanLine(seg, 10, 10, 12 * 3, &none); // cursor before the 13th char
    try std.testing.expectEqual(@as(usize, 4), sc.rows);
    try std.testing.expectEqual(@as(usize, 2), sc.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), sc.cursor_col); // 2 chars into the row
    // Cursor at EOL: last row, col 10 (exact fill; render clamps for parking).
    const sc2 = scanLine(seg, 10, 10, seg.len, &none);
    try std.testing.expectEqual(@as(usize, 3), sc2.cursor_row);
    try std.testing.expectEqual(@as(usize, 10), sc2.cursor_col);
    // Degenerate narrow budget: the first wide char is forced into row 0.
    const sc3 = scanLine(seg[0..6], 1, 10, 0, &none);
    try std.testing.expectEqual(@as(usize, 2), sc3.rows);
    try std.testing.expectEqual(@as(usize, 0), sc3.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), sc3.cursor_col);
}

test "classifyCsi maps kitty Esc (27u)" {
    try std.testing.expect(classifyCsi("27u") == .esc);
    try std.testing.expect(classifyCsi("27;1u") == .esc);
    try std.testing.expect(classifyCsi("13;2u") == .newline);
}

test "ctrlLetterByte reverses kitty ctrl+letter CSI u encodings" {
    // The keys ziv binds (spec legacy table: codepoint - 96 = C0 byte).
    try std.testing.expectEqual(@as(?u8, 0x03), ctrlLetterByte("99;5u")); // Ctrl-C
    try std.testing.expectEqual(@as(?u8, 0x12), ctrlLetterByte("114;5u")); // Ctrl-R
    try std.testing.expectEqual(@as(?u8, 0x04), ctrlLetterByte("100;5u")); // Ctrl-D
    try std.testing.expectEqual(@as(?u8, 0x1a), ctrlLetterByte("122;5u")); // Ctrl-Z
    try std.testing.expectEqual(@as(?u8, 0x0a), ctrlLetterByte("106;5u")); // Ctrl-J
    try std.testing.expectEqual(@as(?u8, 0x01), ctrlLetterByte("97;6u")); // ctrl+shift kept C0, like legacy
    // Non-letters / other modifiers stay unmapped.
    try std.testing.expect(ctrlLetterByte("13;2u") == null);
    try std.testing.expect(ctrlLetterByte("27u") == null);
    try std.testing.expect(ctrlLetterByte("99;7u") == null); // ctrl+alt — legacy was ESC+C0, ignore
    try std.testing.expect(ctrlLetterByte("51;5u") == null); // '3' has no C0 mapping here
    // classifyCsi routes them to the .ctrl action.
    try std.testing.expect(classifyCsi("99;5u") == .ctrl);
    try std.testing.expect(classifyCsi("114;5u") == .ctrl);
    try std.testing.expect(classifyCsi("200~") == .paste_start); // unaffected
}

/// Editor whose render() flushes to /dev/null (render always flushes).
fn testEditor(aw: *std.Io.Writer.Allocating, fw: *std.Io.File.Writer, buf: []u8) Editor {
    return .{ .w = &aw.writer, .file_writer = fw, .r = undefined, .prompt = "> ", .buf = buf };
}

test "render paints a bounded block and clears it whole on repaint" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const nf = try std.Io.Dir.openFileAbsolute(io_state.io(), "/dev/null", .{ .mode = .write_only });
    defer nf.close(io_state.io());
    var fw_buf: [256]u8 = undefined;
    var fw = std.Io.File.Writer.initStreaming(.{ .handle = nf.handle, .flags = .{ .nonblocking = false } }, io_state.io(), &fw_buf);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const old_w = force_width;
    defer force_width = old_w;
    force_width = 20;

    // 30 CJK chars = 60 cols: 9 on row 0 (18-col budget after "> "),
    // 10 per continuation row → 9+10+10+1.
    var buf: [256]u8 = undefined;
    var ed = testEditor(&aw, &fw, &buf);
    try ed.insertBytes("一二三四五六七八九十甲乙丙丁戊己庚辛壬癸一二三四五六七八九十");
    try ed.render();
    try std.testing.expectEqual(@as(usize, 4), ed.last_rows);
    try std.testing.expectEqual(@as(usize, 3), ed.park_row); // cursor at EOL

    // Repaint must clear EVERY row of the previous block — the old
    // single-row clear smeared one full copy per keystroke (the screen
    // explosion on overwidth input).
    const before = aw.written().len;
    try ed.render();
    const second = aw.written()[before..];
    var clears: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, second, idx, "\x1b[2K")) |p| {
        clears += 1;
        idx = p + 1;
    }
    try std.testing.expectEqual(@as(usize, 4), clears);
}

test "render shows every logical line, not just the cursor's" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const nf = try std.Io.Dir.openFileAbsolute(io_state.io(), "/dev/null", .{ .mode = .write_only });
    defer nf.close(io_state.io());
    var fw_buf: [256]u8 = undefined;
    var fw = std.Io.File.Writer.initStreaming(.{ .handle = nf.handle, .flags = .{ .nonblocking = false } }, io_state.io(), &fw_buf);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const old_w = force_width;
    defer force_width = old_w;
    force_width = 40;

    var buf: [64]u8 = undefined;
    var ed = testEditor(&aw, &fw, &buf);
    try ed.insertBytes("aaaa\nbbbb");
    try ed.render();
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "> aaaa\r\nbbbb") != null);
}

test "render windows huge multi-line buffers around the cursor" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const nf = try std.Io.Dir.openFileAbsolute(io_state.io(), "/dev/null", .{ .mode = .write_only });
    defer nf.close(io_state.io());
    var fw_buf: [256]u8 = undefined;
    var fw = std.Io.File.Writer.initStreaming(.{ .handle = nf.handle, .flags = .{ .nonblocking = false } }, io_state.io(), &fw_buf);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const old_w = force_width;
    defer force_width = old_w;
    force_width = 40;

    var buf: [512]u8 = undefined;
    var ed = testEditor(&aw, &fw, &buf);
    // 30 lines "l01".."l30"; cursor on line 20 (0-based 19).
    for (0..30) |i| {
        if (i > 0) try ed.insertBytes("\n");
        var lb: [8]u8 = undefined;
        const ls = try std.fmt.bufPrint(&lb, "l{d:0>2}", .{i + 1});
        try ed.insertBytes(ls);
    }
    // Walk the cursor to line 20's end: skip 19 newlines from the start.
    var nl_seen: usize = 0;
    var p: usize = 0;
    while (nl_seen < 19) : (p += 1) {
        if (ed.buf[p] == '\n') nl_seen += 1;
    }
    ed.pos = p; // after the 19th newline = start of line 20
    try ed.render();
    const out = aw.written();
    // Window: cur_line 19, budget 14 → lines 0-based 12..25 (1-based 13..26),
    // 12 clipped above, 4 below; block = 14 rows + 2 edges = 16.
    try std.testing.expect(std.mem.indexOf(u8, out, "↟ +12 行") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "↡ +4 行") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "l20") != null); // cursor line visible
    try std.testing.expect(ed.last_rows <= MAX_VIEW_ROWS);
}

// ── Paste-fold tests ──────────────────────────────────────────────────

test "marker helpers: detect, step atomically, unforgeable via paste" {
    var m: [3]u8 = undefined;
    const mk = markerBytes(2, &m);
    try std.testing.expectEqualSlices(u8, &.{ 0, '2', 0 }, mk);
    const buf = "ab\x00" ++ "2" ++ "\x00" ++ "cd";
    try std.testing.expectEqual(@as(usize, 3), markerLen(buf, 2));
    try std.testing.expectEqual(@as(usize, 0), markerLen(buf, 0));
    // Glyph stepping jumps the whole marker in both directions.
    try std.testing.expectEqual(@as(usize, 5), nextGlyph(buf, 2));
    try std.testing.expectEqual(@as(usize, 2), prevGlyph(buf, 5));
    // NULs never survive staging (control-byte filter) — markers
    // unforgeable through the paste path.
    {
        var sbuf: [8]u8 = undefined;
        var staged: []u8 = &sbuf;
        var pl: usize = 1;
        var sk = false;
        const n = try Editor.stageBytes(std.testing.allocator, &staged, 0, "a\x00b", &pl, &sk);
        try std.testing.expectEqual(@as(usize, 2), n); // NUL dropped
        try std.testing.expectEqualStrings("ab", staged[0..n]);
    }
}

test "expandPasted replaces markers with the full stored paste" {
    const alloc = std.testing.allocator;
    const data0: []u8 = try alloc.dupe(u8, "LINE-A\nLINE-B\nLINE-C");
    defer alloc.free(data0);
    const data1: []u8 = try alloc.dupe(u8, "second paste");
    defer alloc.free(data1);
    var slots: [PASTE_SLOTS]?PasteSlot = @splat(null);
    slots[0] = .{ .data = data0, .lines = 3 };
    slots[1] = .{ .data = data1, .lines = 1 };
    var m0: [3]u8 = undefined;
    var m1: [3]u8 = undefined;
    const line = try std.fmt.allocPrint(alloc, "before {s} mid {s} after", .{ markerBytes(0, &m0), markerBytes(1, &m1) });
    defer alloc.free(line);
    const exp = (try expandPasted(alloc, line, &slots)).?;
    defer alloc.free(exp);
    try std.testing.expectEqualStrings("before LINE-A\nLINE-B\nLINE-C mid second paste after", exp);
    // No marker → null (caller keeps the original slice).
    try std.testing.expect((try expandPasted(alloc, "plain", &slots)) == null);
}

test "glyphWidth gives a pill real width for layout math" {
    var none: [PASTE_SLOTS]?PasteStat = @splat(null);
    // Slot without data: degenerate pill still has text width.
    var buf: [8]u8 = .{ 0, '0', 0, 0, 0, 0, 0, 0 };
    const w_bare = glyphWidth(buf[0..3], 0, &none);
    try std.testing.expect(w_bare > 0);
    // With stats the pill is wider.
    var stats: [PASTE_SLOTS]?PasteStat = @splat(null);
    stats[0] = .{ .lines = 40, .bytes = 2100 };
    const w_full = glyphWidth(buf[0..3], 0, &stats);
    try std.testing.expect(w_full > w_bare);
    _ = &buf;
}

test "backspace deletes a pill atomically" {
    var buf: [16]u8 = undefined;
    var ed = Editor{ .w = undefined, .file_writer = undefined, .r = undefined, .prompt = ">", .buf = &buf };
    try ed.insertBytes("ab");
    var m: [3]u8 = undefined;
    try ed.insertBytes(markerBytes(1, &m));
    try std.testing.expectEqual(@as(usize, 5), ed.len);
    ed.backspace(); // one press removes the whole marker
    try std.testing.expectEqualStrings("ab", ed.buf[0..ed.len]);
    try std.testing.expectEqual(@as(usize, 2), ed.pos);
}

test "pasteBody folds a big paste into a marker + slot" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    // 20 short lines > PASTE_FOLD_LINES → folds.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    for (0..20) |i| {
        if (i > 0) try body.append(alloc, '\n');
        try body.appendSlice(alloc, "row");
    }
    const stream = try std.fmt.allocPrint(alloc, "{s}\x1b[201~", .{body.items});
    defer alloc.free(stream);
    var reader = std.Io.Reader.fixed(stream);
    const buf = try alloc.alloc(u8, 64);
    defer alloc.free(buf);
    var ed = Editor{
        .w = &aw.writer,
        .file_writer = undefined,
        .r = &reader,
        .prompt = ">",
        .buf = buf,
        .grow = alloc,
        .owned_buf = buf,
    };
    try ed.pasteBody();
    try std.testing.expectEqual(@as(usize, 3), ed.len); // just the marker
    try std.testing.expect(markerLen(ed.buf[0..ed.len], 0) == 3);
    const slot = ed.pastes[0].?;
    try std.testing.expectEqual(@as(usize, 20), slot.lines);
    try std.testing.expectEqualStrings(body.items, slot.data);
    alloc.free(slot.data); // readLine's defer would; here manual

    // Small paste (< thresholds) lands raw, no marker, no slot.
    var reader2 = std.Io.Reader.fixed("tiny\x1b[201~");
    const buf2 = try alloc.alloc(u8, 64);
    defer alloc.free(buf2);
    var ed2 = Editor{ .w = &aw.writer, .file_writer = undefined, .r = &reader2, .prompt = ">", .buf = buf2, .grow = alloc, .owned_buf = buf2 };
    try ed2.pasteBody();
    try std.testing.expectEqualStrings("tiny", ed2.buf[0..ed2.len]);
    try std.testing.expect(ed2.pastes[0] == null);
}

test "folded paste renders as a pill and keeps the block tiny" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const nf = try std.Io.Dir.openFileAbsolute(io_state.io(), "/dev/null", .{ .mode = .write_only });
    defer nf.close(io_state.io());
    var fw_buf: [256]u8 = undefined;
    var fw = std.Io.File.Writer.initStreaming(.{ .handle = nf.handle, .flags = .{ .nonblocking = false } }, io_state.io(), &fw_buf);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const old_w = force_width;
    defer force_width = old_w;
    force_width = 80;

    var buf: [64]u8 = undefined;
    var ed = testEditor(&aw, &fw, &buf);
    ed.grow = alloc;
    const pd = try alloc.dupe(u8, "line\nline\nline");
    ed.pastes[0] = .{ .data = pd, .lines = 40 };
    var m: [3]u8 = undefined;
    try ed.insertBytes("see ");
    try ed.insertBytes(markerBytes(0, &m));
    try ed.render();
    // Pill text present, block is ONE row, cursor parked after the pill.
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "[📄 粘贴 · 40 行") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0) == null); // no NUL leaked
    try std.testing.expectEqual(@as(usize, 1), ed.last_rows);
    alloc.free(pd);
}

// ── P4: generation-period live input tests ──

fn resetPendingState() void {
    pending_len = 0;
    pending_shown = false;
    queued_count = 0;
    queued_read = 0;
    @memset(&queued_lens, 0);
    typeahead_len = 0;
}

test "pending submit queues FIFO and queuedTake pops in order" {
    resetPendingState();
    // "abc" + Enter, then CJK "\u{7B2C}\u{4E8C}" (di-er) + Enter — UTF-8 multibyte
    const cjk = "\u{7B2C}\u{4E8C}";
    for ("abc") |c| pendingAppend(c, null);
    try std.testing.expect(pendingSubmit(null));
    for (cjk) |c| pendingAppend(c, null);
    try std.testing.expect(pendingSubmit(null));
    try std.testing.expectEqual(@as(usize, 2), queued_count);

    const first = queuedTake().?;
    try std.testing.expectEqualStrings("abc", first);
    const second = queuedTake().?;
    try std.testing.expectEqualStrings(cjk, second);
    try std.testing.expect(queuedTake() == null);
    try std.testing.expectEqual(@as(usize, 0), queued_count);
}

test "pending backspace removes whole runes; empty submit is a no-op" {
    resetPendingState();
    const cjk2 = "\u{4E2D}\u{6587}x"; // zhong-wen + x
    for (cjk2) |c| pendingAppend(c, null);
    pendingBackspace(null); // drop 'x'
    pendingBackspace(null); // drop the second CJK rune atomically
    try std.testing.expectEqual(@as(usize, 3), pending_len);
    try std.testing.expectEqualSlices(u8, "\u{4E2D}", pending_buf[0..pending_len]);
    pendingBackspace(null);
    try std.testing.expectEqual(@as(usize, 0), pending_len);
    try std.testing.expect(!pendingSubmit(null));
    try std.testing.expectEqual(@as(usize, 0), queued_count);
}

test "unsubmitted pending merges into typeahead for the editor" {
    resetPendingState();
    for ("draft") |c| pendingAppend(c, null);
    pendingMergeIntoTypeahead();
    try std.testing.expectEqual(@as(usize, 0), pending_len);
    try std.testing.expectEqualSlices(u8, "draft", typeahead_buf[0..typeahead_len]);
    try std.testing.expectEqual(@as(usize, 0), queued_count);
}

test "esc sequence classification: paste markers vs cancel" {
    try std.testing.expectEqual(EscSeq.paste_start, classifyEscSeq("[200~"));
    try std.testing.expectEqual(EscSeq.paste_end, classifyEscSeq("[201~"));
    try std.testing.expectEqual(EscSeq.cancel, classifyEscSeq("[A")); // arrow
    try std.testing.expectEqual(EscSeq.cancel, classifyEscSeq("")); // bare Esc
    try std.testing.expectEqual(EscSeq.cancel, classifyEscSeq("[27u")); // kitty Esc
}

test "escProbe paste flow: markers feed pending, CR queues, no cancel" {
    resetPendingState();
    defer resetPendingState();
    // Drive the byte machine one byte at a time (escProbe's drain gate
    // polls fd 0, which has no data under the test runner — Reader.fixed
    // never reports bufferedLen either). Production drain behavior is
    // covered by the pty E2Es.
    const burst = "\x1b[200~hello paste\x1b[201~\r";
    var fr = std.Io.Reader.fixed(burst);
    var cancelled = false;
    for (0..burst.len + 2) |_| {
        if (escProbeOne(&fr, null)) {
            cancelled = true;
            break;
        }
    }
    try std.testing.expect(!cancelled); // paste must NOT cancel
    // The trailing CR moved the pasted text into the queue (that IS the
    // design): pending is empty, the queued message holds it.
    try std.testing.expectEqual(@as(usize, 0), pending_len);
    try std.testing.expectEqual(@as(usize, 1), queued_count);
    try std.testing.expectEqualStrings("hello paste", queued_msgs[0][0..queued_lens[0]]);
    try std.testing.expect(!paste_active);

    // a bare Esc after that still cancels (arrow keys etc. unchanged)
    var fr2 = std.Io.Reader.fixed("\x1b[A");
    try std.testing.expect(escProbeOne(&fr2, null));
}
