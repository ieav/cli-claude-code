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

/// Terminal width for callers outside the editor (the stream line
/// buffer's soft-wrap flush points).
pub fn currentTermWidth() usize {
    return @max(effWidth(), 8);
}

/// Terminal column count via TIOCGWINSZ; 80 as the conservative fallback.
fn termWidth() usize {
    var ws: std.c.winsize = undefined;
    if (std.c.ioctl(0, std.c.T.IOCGWINSZ, &ws) == 0 and ws.col > 0) return ws.col;
    return 80;
}

/// Test hooks: nonzero overrides TIOCGWINSZ so renderer math is testable.
pub var force_width: usize = 0;
pub var force_height: usize = 0;

fn effWidth() usize {
    return if (force_width != 0) force_width else termWidth();
}

/// Terminal row count via TIOCGWINSZ; 24 as the conservative fallback
/// (the scroll-region math clamps on tiny terminals anyway).
fn termHeight() usize {
    if (force_height != 0) return force_height;
    var ws: std.c.winsize = undefined;
    if (std.c.ioctl(0, std.c.T.IOCGWINSZ, &ws) == 0 and ws.row > 0) return ws.row;
    return 24;
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

/// ── P1 (tui-event-loop): the session editor ─────────────────────────
/// ONE Editor instance for the whole process, lazily created on the
/// first readLine and reused by every later one AND by the
/// generation-period key pump (editorLiveKey) — the buffer survives
/// across a turn boundary, so a draft typed mid-generation is the SAME
/// draft the next prompt opens with. No handoff, no typeahead merge.
/// The initial allocation (and any growth) lives until editorDeinit.
var live_ed: ?*Editor = null;
var live_ed_buf: []u8 = &.{};

pub fn editorLive() ?*Editor {
    return live_ed;
}

/// Session teardown (process exit / tests): releases the persistent
/// buffer. After this the next readLine lazily re-creates the editor.
pub fn editorDeinit(alloc: std.mem.Allocator) void {
    if (live_ed) |ed| {
        ed.releaseSlots();
        if (ed.draft_owned) |d| alloc.free(d);
        alloc.destroy(ed);
        live_ed = null;
    }
    if (live_ed_buf.len > 0) {
        alloc.free(live_ed_buf);
        live_ed_buf = &.{};
    }
}

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

/// ── Turn-scoped live region state ─────────────────────────────────────
/// The persistent editor IS the live draft (P1): keystrokes during a
/// generation edit it directly via editorLiveKey; the input row renders
/// its tail. Enter QUEUES the draft as a message: the agent loop injects
/// it between tool rounds, and anything still queued when the turn ends
/// auto-submits as the next message.
/// The drawn region occupies TWO screen rows (status on top, input below).
pub var pending_shown: bool = false;
/// Status row ABOVE the pending input row (elapsed wait / queue info).
/// Written by the REPL's tick handler; both rows form the turn-scoped
/// live region. Empty = no status row. The status sits ABOVE the input
/// row so the input row is always the LAST screen row — the natural
/// prompt-at-bottom position.
pub var pending_status_buf: [96]u8 = undefined;
pub var pending_status_len: usize = 0;
/// The REAL prompt prefix ("ziv (model) [42%] > ") for the region's input
/// row — set by the REPL whenever it builds the prompt. The turn-scoped
/// input row renders with the SAME identity as the readLine editor, so
/// typed text never changes appearance or position when the turn ends
/// (the old "⌨" dim row next to a bright editor row read as two
/// different input areas).
pub var pending_prompt_buf: [192]u8 = undefined;
pub var pending_prompt_len: usize = 0;
/// The drawn region occupies TWO screen rows (status on top, input below).
pub var pending_status_shown: bool = false;

pub fn regionPromptSet(s: []const u8) void {
    const n = @min(s.len, pending_prompt_buf.len);
    @memcpy(pending_prompt_buf[0..n], s[0..n]);
    pending_prompt_len = n;
}

fn pendingPrompt() []const u8 {
    return pending_prompt_buf[0..pending_prompt_len];
}

pub fn pendingStatusSet(s: []const u8) void {
    const n = @min(s.len, pending_status_buf.len);
    @memcpy(pending_status_buf[0..n], s[0..n]);
    pending_status_len = n;
}

pub fn queuedCount() usize {
    return queued_count - queued_read;
}

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
/// P1 visibility: whether each slot's message was already ECHOED into the
/// transcript at QUEUE time (the user must SEE what they queued, not a
/// bare counter). Injection/auto-send consult the flag via
/// last_take_echoed to avoid double echoes.
pub var queued_echoed: [QUEUED_MAX]bool = @splat(false);
/// Set by queuedTake: whether the returned message was already echoed.
pub var last_take_echoed: bool = false;

/// True while unconsumed messages remain.
pub fn queuedHas() bool {
    return queued_read < queued_count;
}

/// Hand out the oldest unconsumed message. The slice stays valid until
/// the queue fully drains (compaction) — read or dupe it promptly.
/// `last_take_echoed` reports whether it was already shown in the
/// transcript at queue time.
pub fn queuedTake() ?[]const u8 {
    if (queued_read >= queued_count) {
        queued_count = 0;
        queued_read = 0;
        @memset(&queued_lens, 0);
        @memset(&queued_echoed, false);
        return null;
    }
    const out = queued_msgs[queued_read][0..queued_lens[queued_read]];
    last_take_echoed = queued_echoed[queued_read];
    queued_read += 1;
    return out;
}

/// P1: the live draft = the persistent editor's buffer (generation-period
/// keystrokes edit the SAME draft the prompt shows). Empty when no editor
/// exists yet (before the first readLine).
fn liveDraft() []const u8 {
    const ed = live_ed orelse return "";
    return ed.buf[0..ed.len];
}

/// Whether the live editor is browsing input history (browse rows paint
/// magenta in the prompt renderer; the pinned block uses the same rule's
/// negation for slash coloring eligibility).
fn self_browsing() bool {
    const ed = live_ed orelse return false;
    return ed.browsing;
}

/// Display-capped tail of the live draft, cut at a UTF-8 boundary and
/// fitting the terminal width minus the prompt prefix (the input row must
/// stay ONE row — an overflowing echo would wrap over the status row).
/// Interim single-row view: the P3 renderer gives the editor its full
/// multi-row block back.
fn editorTail() []const u8 {
    const s = liveDraft();
    const tw = currentTermWidth(); // honors the force_width test hook
    var budget: usize = if (tw > 40) tw - 40 else 16;
    const pw = strWidth(pendingPrompt());
    if (tw > pw + 2) budget = tw - pw - 2;
    var i = s.len;
    var cols: usize = 0;
    while (i > 0) {
        // walk back one rune
        var start = i - 1;
        while (start > 0 and (s[start] & 0xC0) == 0x80) start -= 1;
        const rune_cols: usize = if (s[start] >= 0xE0) 2 else 1;
        if (cols + rune_cols > budget) break;
        cols += rune_cols;
        i = start;
    }
    return s[i..];
}

/// ── P3: turn-scoped live region (DECSTBM scroll-region protocol) ────
/// The terminal is split by a scroll region: rows [1, H-2] are the
/// TRANSCRIPT (scrolls), the bottom TWO rows are PINNED (status above,
/// the prompt-identical input row below) and are written with absolute
/// cursor addressing only. A transcript line prints at the region's
/// bottom-left and scrolls WITHIN the region — the pinned rows are never
/// cleared for transcript growth, which is exactly what flickered in the
/// old clear-and-repaint protocol. Repaints touch only the changed row.
/// Height the region was armed with (resize detection re-applies bounds).
var region_h: usize = 0;

/// Max editor block rows during a generation (prompt-identical window on
/// the draft; matches MAX_VIEW_ROWS' spirit, smaller to keep the
/// transcript area on short terminals).
const MAX_LIVE_BLOCK_ROWS: usize = 6;

/// The editor block's CURRENT row count (>=1): soft-wrapped display rows
/// of the persistent draft, prompt sharing row 0, tail-windowed with a
/// "↟ +N" marker row when clipped — the same reading model as the
/// readLine editor, so a multi-line draft during a generation is fully
/// legible (P3b).
fn blockRows() usize {
    if (liveDraft().len == 0) return 1;
    var rows: usize = 0;
    var first = true;
    var it = std.mem.splitScalar(u8, liveDraft(), '\n');
    const tw = currentTermWidth();
    const pw = strWidth(pendingPrompt());
    while (it.next()) |logical| {
        const avail: usize = if (first) (if (tw > pw) tw - pw else 1) else tw;
        // Wrapped-row count by display width (wide chars never split —
        // count like scanLine but only the row total).
        var col: usize = 0;
        var r: usize = 1;
        var i: usize = 0;
        while (i < logical.len) {
            const next = nextChar(logical, i);
            const cw = strWidth(logical[i..next]);
            if (col > 0 and col + cw > avail) {
                r += 1;
                col = 0;
            }
            col += cw;
            i = next;
        }
        first = false;
        rows += r;
    }
    if (rows > MAX_LIVE_BLOCK_ROWS) return MAX_LIVE_BLOCK_ROWS + 1; // + ↟ marker row
    return @max(rows, 1);
}

/// Split row = last transcript row = H - (1 status + block rows).
fn regionRows() usize {
    const h = @max(region_h, 4);
    const split = h -| (1 + blockRows());
    return @max(split, 1);
}

/// (Re)apply the scroll-region bounds and paint all pinned rows fresh:
/// one status row + the editor block's rows.
var last_block_rows: usize = 0;

/// Serializes every terminal-mutating sequence across threads. During a
/// turn the UI thread repaints the pinned rows (keystrokes via
/// renderPendingLine, the 500ms status tick via regionStatus) WHILE the
/// tool/stream worker prints transcript lines (regionPrintLine through
/// RegionWriter). Each print is a multi-step escape dance sharing ONE
/// DECSC cursor slot (`\x1b8` restore flow → write → `\x1b7` save flow →
/// park); a status/keystroke paint interleaved between the write and the
/// save stores the PARKED input-row position as the transcript flow, and
/// every later transcript line then lands ON the input block — the
/// "long turn corrupts the input area" bug. One lock per whole
/// operation; public fns hold it, internal *Locked fns assume it.
var tty_mu: std.Io.Mutex = .init;

/// std.Io.Mutex's lock/unlock take the Io instance; the terminal paths
/// here only ever see *std.Io.Writer, so repl.run injects its Io once at
/// startup. Null (unit tests, pre-init) degrades to NO locking — those
/// callers are single-threaded by construction.
var tty_io: ?std.Io = null;

pub fn setIo(io: std.Io) void {
    tty_io = io;
}

/// P3c Ctrl+O（与 Claude Code 的 verbose 开关同键）：切换工具输出的
/// 详细/简要。回调由 repl 装配（layering：util 层不 import turn 层）。
/// 回调返回新的详细态文案，供此处打印一行转录提示。
pub var on_verbose_toggle: ?*const fn () []const u8 = null;

fn ttyLock() void {
    const io = tty_io orelse return;
    tty_mu.lockUncancelable(io);
}

fn ttyUnlock() void {
    const io = tty_io orelse return;
    tty_mu.unlock(io);
}

/// Push the real writer's buffered bytes OUT before releasing tty_mu.
/// Every locked op then leaves the buffer empty, so the REPL's legacy
/// call-site flushes (outside any lock) can never race a half-written
/// escape sequence — on an empty buffer they are harmless no-ops.
fn flushReal(w: *std.Io.Writer) void {
    std.Io.Writer.flush(w) catch {};
}

/// (Re)apply the scroll-region bounds and paint all pinned rows fresh.
/// The transcript FLOW position (where the conversation prints) is the
/// cursor position at arm time — preserved across the DECSTBM change by
/// DECSC/DECRC. From then on: transcript lines print RELATIVELY at the
/// flow position (content grows downward from the top — no bottom-gap),
/// pinned rows paint with ABSOLUTE positioning, and the visible cursor
/// parks at the input block's end (the typing position).
fn regionApply(w: *std.Io.Writer) void {
    const h = @max(termHeight(), 4);
    region_h = h;
    const split = regionRows();
    last_block_rows = blockRows();
    if (!pending_shown) {
        // FIRST ARM. The cursor sits at the FLOW position (right after
        // the committed echo) — on an UNKNOWN row R (full-screen shell
        // history puts it at the bottom; a fresh screen near the top).
        // If R is below the split, naive printing lands ON the pinned
        // rows and erases itself ("nothing visible"). Fix WITHOUT
        // knowing R: scroll the WHOLE screen up by the pinned-row count
        // (SU), then move the cursor up the same amount — the content
        // that was at R is now at R-N, and CUU clamps at the top margin
        // for fresh screens, so every case lands inside the region.
        const n = h - split; // pinned rows: status + block
        std.Io.Writer.writeAll(w, "\x1b7") catch {}; // save flow (R,col)
        std.Io.Writer.writeAll(w, "\x1b[r") catch {}; // full-screen region
        std.Io.Writer.print(w, "\x1b[{d}S", .{n}) catch {}; // push all up n
        std.Io.Writer.print(w, "\x1b[1;{d}r", .{split}) catch {}; // real bounds (homes)
        std.Io.Writer.writeAll(w, "\x1b8") catch {}; // back to (R,col)
        std.Io.Writer.print(w, "\x1b[{d}A", .{n}) catch {}; // follow content: R-n (clamped)
        std.Io.Writer.writeAll(w, "\x1b7") catch {}; // re-save corrected flow
    } else {
        // RE-APPLY (block height changed / resize): the DECSC slot still
        // holds the FLOW position — do NOT touch it. DECSTBM homes the
        // cursor, which is fine: everything below paints absolutely and
        // parks explicitly. (Saving here would clobber the flow with the
        // parked typing position — every later transcript line then
        // printed ONTO the input block and erased itself: "nothing
        // visible".)
        std.Io.Writer.print(w, "\x1b[1;{d}r", .{split}) catch {};
    }
    // Status row (absolute), dim.
    std.Io.Writer.print(w, "\x1b[{d};1H\x1b[2K", .{split + 1}) catch {};
    if (pending_status_len > 0) {
        std.Io.Writer.print(w, "\x1b[2m{s}\x1b[0m", .{pending_status_buf[0..pending_status_len]}) catch {};
    }
    writeEditorBlock(w);
    pending_shown = true;
    pending_status_shown = true;
}

/// Paint the editor block into its pinned rows (absolute): every soft-
/// wrapped display row of the draft, prompt sharing row 0, tail-windowed
/// to MAX_LIVE_BLOCK_ROWS with a dim "↟ +N" marker row when clipped.
/// Cursor parks at the end of the LAST row's text — the typing position.
fn writeEditorBlock(w: *std.Io.Writer) void {
    const split = regionRows();
    const tw = currentTermWidth();
    const pw = strWidth(pendingPrompt());

    // Collect display rows first (tail window decision needs the total).
    var rows_buf: [64][]const u8 = undefined;
    var nrows: usize = 0;
    var first_logical = true;
    var iter = std.mem.splitScalar(u8, liveDraft(), '\n');
    while (iter.next()) |logical| {
        const avail: usize = if (first_logical) (if (tw > pw) tw - pw else 1) else tw;
        var col: usize = 0;
        var i: usize = 0;
        var row_start: usize = 0;
        while (i <= logical.len) {
            if (i == logical.len or (col > 0 and blk: {
                const next = nextChar(logical, i);
                const cw = strWidth(logical[i..next]);
                break :blk col + cw > avail;
            })) {
                if (nrows < rows_buf.len) {
                    rows_buf[nrows] = logical[row_start..i];
                    nrows += 1;
                }
                row_start = i;
                col = 0;
                if (i == logical.len) break;
            }
            const next = nextChar(logical, i);
            col += strWidth(logical[i..next]);
            i = next;
        }
        first_logical = false;
    }
    if (nrows == 0) nrows = 1; // empty draft: one blank input row

    const hidden = nrows -| MAX_LIVE_BLOCK_ROWS;
    const start = if (nrows > MAX_LIVE_BLOCK_ROWS) hidden else 0;
    var row_idx = split + 2;
    if (hidden > 0) {
        std.Io.Writer.print(w, "\x1b[{d};1H\x1b[2K\x1b[2m↟ +{d} 行\x1b[0m", .{ row_idx, hidden }) catch {};
        row_idx += 1;
    }
    // P3c 配色：与提示符层编辑器同一套斜杠规则——已知命令 cyan、
    // 未知灰（StyleState 的判定在 emitLineP 侧；此处是钉行区的孪生
    // 实现，token 上限钳到本显示行的字节范围防软换行越界）。
    var slash_tok: usize = 0;
    var slash_known = false;
    {
        const draft = liveDraft();
        if (!self_browsing() and draft.len > 0 and draft[0] == '/') {
            const l0_len = std.mem.indexOfScalar(u8, draft, '\n') orelse draft.len;
            const tok_end = std.mem.indexOfScalar(u8, draft[0..l0_len], ' ') orelse l0_len;
            slash_tok = tok_end;
            slash_known = lineinput_cmds.isKnownCommand(draft[0..tok_end]);
        }
    }
    var shown = start;
    while (shown < nrows and shown - start < MAX_LIVE_BLOCK_ROWS) : (shown += 1) {
        std.Io.Writer.print(w, "\x1b[{d};1H\x1b[2K", .{row_idx}) catch {};
        if (shown == 0 and hidden == 0) {
            std.Io.Writer.writeAll(w, pendingPrompt()) catch {};
        }
        const row = rows_buf[shown];
        const color_head = shown == 0 and slash_tok > 0 and slash_tok <= row.len;
        if (color_head) {
            std.Io.Writer.writeAll(w, if (slash_known) "\x1b[36m" else "\x1b[90m") catch {};
            std.Io.Writer.writeAll(w, row[0..slash_tok]) catch {};
            std.Io.Writer.writeAll(w, "\x1b[0m") catch {};
            std.Io.Writer.writeAll(w, row[slash_tok..]) catch {};
        } else {
            std.Io.Writer.writeAll(w, row) catch {};
        }
        row_idx += 1;
    }
    if (nrows > 0 and start >= nrows) {
        // Degenerate (shouldn't happen): keep an empty input row.
        std.Io.Writer.print(w, "\x1b[{d};1H\x1b[2K", .{row_idx}) catch {};
        std.Io.Writer.writeAll(w, pendingPrompt()) catch {};
    }
}

/// True while the region is armed — REPL output funnels through
/// regionPrintLine/RegionWriter so the persistent input row is never
/// overwritten.
pub fn regionUp() bool {
    return pending_shown;
}

/// Show the region with the given status: split the screen and pin the
/// two rows. The cursor ends on the input row after its text.
pub fn regionBegin(w: *std.Io.Writer, status: []const u8) void {
    ttyLock();
    defer ttyUnlock();
    pendingStatusSet(status);
    regionApply(w);
    flushReal(w);
}

/// Print one complete output line into the TRANSCRIPT area: park at the
/// scroll region's bottom-left and write (the trailing newline scrolls
/// the region; the pinned rows are untouched). Region down = plain
/// passthrough at the cursor.
pub fn regionPrintLine(w: *std.Io.Writer, line: []const u8) void {
    ttyLock();
    defer ttyUnlock();
    regionPrintLineLocked(w, line);
    flushReal(w);
}

fn regionPrintLineLocked(w: *std.Io.Writer, line: []const u8) void {
    if (!pending_shown) {
        std.Io.Writer.writeAll(w, line) catch {};
        if (line.len == 0 or line[line.len - 1] != '\n') {
            std.Io.Writer.writeAll(w, "\n") catch {};
        }
        return;
    }
    // Resize between frames: re-apply bounds before printing.
    if (termHeight() != region_h) regionApply(w);
    // Return to the flow position (saved by the last print/paint), write
    // RELATIVELY — the conversation grows downward from wherever it is;
    // the trailing newline scrolls the region only at its bottom row.
    std.Io.Writer.writeAll(w, "\x1b8") catch {};
    std.Io.Writer.writeAll(w, line) catch {};
    if (line.len == 0 or line[line.len - 1] != '\n') {
        std.Io.Writer.writeAll(w, "\n") catch {};
    }
    // Save the ADVANCED flow position, then park the visible cursor on
    // the input block's last row (the typing position).
    std.Io.Writer.writeAll(w, "\x1b7") catch {};
    parkCursor(w);
}

/// Park the cursor at the end of the editor block's last visible row.
fn parkCursor(w: *std.Io.Writer) void {
    const last = editorTail();
    var cols = strWidth(pendingPrompt());
    cols += strWidth(last);
    std.Io.Writer.print(w, "\x1b[{d};{d}H", .{ region_h, cols + 1 }) catch {};
}

/// In-place repaint of the pinned rows (keystroke path): status row only
/// when its text changed is handled by regionStatus; here both rows get
/// refreshed (the draft changed).
pub fn renderPendingLine(w: *std.Io.Writer) void {
    ttyLock();
    defer ttyUnlock();
    renderPendingLineLocked(w);
    flushReal(w);
}

fn renderPendingLineLocked(w: *std.Io.Writer) void {
    if (liveDraft().len == 0 and pending_status_len == 0) {
        if (pending_shown) regionEndLocked(w);
        return;
    }
    if (!pending_shown) {
        regionApply(w);
        return;
    }
    // Terminal resize OR a draft whose row count changed (multi-line
    // growth/shrink) re-applies the DECSTBM bounds; otherwise repaint
    // only the block's rows.
    if (termHeight() != region_h or blockRows() != last_block_rows) {
        regionApply(w);
        return;
    }
    writeEditorBlock(w);
}

/// End of turn: reset the scroll region, erase the pinned rows, park the
/// cursor directly below the transcript's last line — the next prompt
/// prints exactly there. Typed draft text is NOT frozen into the
/// transcript (the persistent editor keeps it for the next prompt).
pub fn regionEnd(w: *std.Io.Writer) void {
    ttyLock();
    defer ttyUnlock();
    regionEndLocked(w);
    flushReal(w);
}

fn regionEndLocked(w: *std.Io.Writer) void {
    if (!pending_shown) {
        pendingStatusSet("");
        return;
    }
    const split = regionRows();
    // Erase every pinned row (status + block), reset the scroll region,
    // and leave the cursor AT THE FLOW POSITION — directly below the
    // transcript's last line, where the next prompt naturally prints.
    // (The old protocol parked on a PINNED row; the next turn's status
    // paint overwrote the message echoed there — "history invisible".)
    std.Io.Writer.writeAll(w, "\x1b7") catch {}; // save flow
    var row = region_h;
    var b: [32]u8 = undefined;
    while (row > split) : (row -= 1) {
        const seq = std.fmt.bufPrint(&b, "\x1b[{d};1H\x1b[2K", .{row}) catch break;
        std.Io.Writer.writeAll(w, seq) catch {};
    }
    std.Io.Writer.writeAll(w, "\x1b[r\x1b8") catch {}; // reset bounds, back to flow
    pending_shown = false;
    pending_status_shown = false;
    region_h = 0;
    last_block_rows = 0;
    pendingStatusSet("");
}

/// End of turn, NORMAL completion: the status text (set via regionStatus
/// right before — the "✓ 完成 · in N → out M" summary) scrolls into the
/// TRANSCRIPT as its last line, then the region comes down. The summary
/// stays visible directly above the next prompt; the in/out numbers the
/// user tracks are never lost.
pub fn regionFreeze(w: *std.Io.Writer) void {
    ttyLock();
    defer ttyUnlock();
    if (pending_shown and pending_status_len > 0) {
        var buf: [128]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "\x1b[2m{s}\x1b[0m\n", .{pending_status_buf[0..pending_status_len]}) catch "";
        regionPrintLineLocked(w, summary);
    }
    regionEndLocked(w);
    flushReal(w);
}

/// Paint the status row (absolute) and park the cursor back on the
/// input row's end. Caller sets pending_status first.
fn paintStatusRow(w: *std.Io.Writer) void {
    const split = regionRows();
    std.Io.Writer.print(w, "\x1b[{d};1H\x1b[2K", .{split + 1}) catch {};
    if (pending_status_len > 0) {
        std.Io.Writer.print(w, "\x1b[2m{s}\x1b[0m", .{pending_status_buf[0..pending_status_len]}) catch {};
    }
    parkCursor(w);
}

/// Refresh the status row only (tick path); the region stays put.
pub fn regionStatus(w: *std.Io.Writer, status: []const u8) void {
    ttyLock();
    defer ttyUnlock();
    pendingStatusSet(status);
    if (!pending_shown) return;
    if (termHeight() != region_h) {
        regionApply(w);
        flushReal(w);
        return;
    }
    paintStatusRow(w);
    // P3c 心跳自愈：500ms 节拍连带重绘输入块——任何瞬态擦除（首挂载
    // 滚屏舞步边界、外部清屏、resize 竞态、未知触发）在半秒内复原，
    // 对"发送后输入区消失"类问题免疫（2026-11-07 用户报障的根治策略）。
    writeEditorBlock(w);
    flushReal(w);
}

/// ── Region-aware transcript writer (the P0-b mechanism) ────────────
///
/// The REPL's business output during a turn funnels through this
/// UNBUFFERED Writer: with the live region UP every write is
/// line-atomic — bytes accumulate until '\n', then print ABOVE the
/// region via regionPrintLine; with the region DOWN bytes forward
/// verbatim (cursor codes, interactive prompts, and multi-write logical
/// lines keep their exact byte stream). Business code can therefore
/// print PLAINLY; a stray direct write can no longer scribble over the
/// persistent input row and desync the region's cursor anchor — the bug
/// class where the diff preview ate transcript rows.
///
/// Reentrancy rule: the region MECHANICS functions (regionBegin/End/
/// Freeze/Status, renderPendingLine, escProbe echo) must keep receiving
/// the REAL writer — this wrapper is for transcript text only.
/// ── Markdown table rendering (v0.7.5) ───────────────────────────────
/// Consecutive transcript lines that look like markdown table rows are
/// buffered and printed as ONE aligned block: column widths computed in
/// DISPLAY columns (CJK counts 2 — strWidth), separator rows (|---|)
/// rendered as a rule line, and an over-wide table shrunk to the current
/// terminal width by truncating the widest cells first. Printed rows are
/// committed — a later resize cannot reflow them (terminal scrollback is
/// immutable; no TUI can), but every table is CORRECT for the width at
/// print time.
/// A candidate table row: starts and ends with '|' after trimming.
fn isTableRow(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return t.len >= 2 and t[0] == '|' and t[t.len - 1] == '|';
}

/// A separator row: every cell between the pipes is only -, :, or empty.
fn isTableSeparator(line: []const u8) bool {
    if (!isTableRow(line)) return false;
    var it = splitCells(line);
    while (it.next()) |cell| {
        for (cell) |ch| {
            if (ch != '-' and ch != ':') return false;
        }
    }
    return true;
}

/// Split "| a | b |" into cells "a", "b" (trimmed; no leading/trailing
/// empty artifacts). Allocator needed only for the slice list.
const CellIter = struct {
    rest: []const u8,
    fn next(self: *CellIter) ?[]const u8 {
        const r = std.mem.trim(u8, self.rest, " \t");
        if (r.len == 0) return null;
        // r starts with '|'
        var rest = r[1..];
        const bar = std.mem.indexOfScalar(u8, rest, '|') orelse return null; // no closing bar
        const cell = std.mem.trim(u8, rest[0..bar], " \t");
        rest = rest[bar..];
        self.rest = rest;
        return cell;
    }
};

fn splitCells(line: []const u8) CellIter {
    return .{ .rest = std.mem.trim(u8, line, " \t") };
}

/// Render the buffered table block into `out` (already newline-joined
/// rows). Width-adaptive: total display width ≤ term width, shrinking
/// the widest columns first (truncate cells with an ellipsis at a rune
/// boundary).
fn renderTableBlock(alloc: std.mem.Allocator, rows: []const []const u8, term_w: usize, out: *std.ArrayList(u8)) !void {
    // Parse all rows into cells; track column count.
    var cell_rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (cell_rows.items) |cr| alloc.free(cr);
        cell_rows.deinit(alloc);
    }
    var max_cols: usize = 0;
    var has_sep = false;
    for (rows) |row| {
        if (isTableSeparator(row)) {
            has_sep = true;
            continue; // replaced by a rule line
        }
        var cells: std.ArrayList([]const u8) = .empty;
        errdefer cells.deinit(alloc);
        var it = splitCells(row);
        while (it.next()) |c| try cells.append(alloc, c);
        max_cols = @max(max_cols, cells.items.len);
        try cell_rows.append(alloc, try cells.toOwnedSlice(alloc));
    }
    if (cell_rows.items.len == 0) return;
    if (max_cols == 0) max_cols = 1;

    // Column widths in display columns ( widest cell per column ).
    const widths = try alloc.alloc(usize, max_cols);
    defer alloc.free(widths);
    @memset(widths, 0);
    for (cell_rows.items) |cr| {
        for (cr, 0..) |c, i| widths[i] = @max(widths[i], strWidth(c));
    }

    // Structure cost: "| " + " | "×(cols-1) + " |\n" = 2*cols + 1.
    const budget: usize = if (term_w > 4) term_w - 2 else 10; // small margin
    // Shrink the widest column by one display column until the table
    // fits the terminal (cells then clip with an ellipsis at emit time).
    while (widthsTotal(widths, max_cols) + 2 * max_cols + 1 > budget) {
        var widest: usize = 0;
        for (widths[1..], 1..) |wd, i| {
            if (wd > widths[widest]) widest = i;
        }
        if (widths[widest] <= 3) break; // nothing left to shave
        widths[widest] -= 1;
    }

    // Emit rows.
    for (cell_rows.items, 0..) |cr, ri| {
        if (has_sep and ri == 1) {
            // Rule line under the header row (replaces the |---| row).
            try out.appendSlice(alloc, "\x1b[2m|");
            for (widths) |wd| {
                var k: usize = 0;
                while (k < wd + 2) : (k += 1) try out.appendSlice(alloc, "\u{2500}");
            }
            try out.appendSlice(alloc, "|\x1b[0m\n");
        }
        try out.append(alloc, '|');
        for (0..max_cols) |ci| {
            const cell = if (ci < cr.len) cr[ci] else "";
            try out.append(alloc, ' ');
            try appendClipped(alloc, out, cell, widths[ci]);
            var pad = widths[ci] -| strWidth(cell);
            while (pad > 0) : (pad -= 1) try out.append(alloc, ' ');
            try out.appendSlice(alloc, " |");
        }
        try out.append(alloc, '\n');
    }
}

fn widthsTotal(w: []const usize, n: usize) usize {
    var t: usize = 0;
    for (w[0..n]) |x| t += x;
    return t;
}

/// Append `s` clipped to `budget` display columns (ellipsis when cut, at
/// a rune boundary).
fn appendClipped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, budget: usize) !void {
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const next = nextChar(s, i);
        const cw = strWidth(s[i..next]);
        if (col + cw > budget) {
            if (budget >= 2) try out.appendSlice(alloc, "…");
            return;
        }
        try out.appendSlice(alloc, s[i..next]);
        col += cw;
        i = next;
    }
}

pub const RegionWriter = struct {
    real: *std.Io.Writer,
    /// Scratch allocator for the markdown-table renderer (null = table
    /// rendering disabled, passthrough).
    table_alloc: ?std.mem.Allocator = null,
    /// Buffered table rows (markdown table detected; flushed as one
    /// aligned block when the table ends).
    table_rows: std.ArrayList([]const u8) = .empty,
    /// Logical line under construction. A complete line (or a full
    /// accumulator — lines longer than the cap flush in pieces, since
    /// regionPrintLine terminates a newline-less payload) prints above
    /// the region immediately. Invariant: line_len < LINE_CAP between
    /// feeds, so the memcpy below always advances.
    line: [LINE_CAP]u8 = undefined,
    line_len: usize = 0,
    interface: std.Io.Writer = .{ .vtable = &vt, .buffer = &.{} },

    pub const LINE_CAP: usize = 8192;

    const vt = std.Io.Writer.VTable{
        .drain = drain,
        .flush = flush,
    };

    fn fromIface(w: *std.Io.Writer) *RegionWriter {
        return @alignCast(@fieldParentPtr("interface", w));
    }

    /// Buffer `bytes` up to the next '\n'; each complete line prints
    /// above the region as one regionPrintLine call. Markdown-table rows
    /// are held back and flushed as one ALIGNED block when the table
    /// ends (see renderTableBlock).
    fn feed(self: *RegionWriter, bytes: []const u8) void {
        ttyLock();
        defer ttyUnlock();
        self.feedLocked(bytes);
    }

    fn feedLocked(self: *RegionWriter, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const take = if (nl) |i| i + 1 else rest.len;
            var seg = rest[0..take];
            rest = rest[take..];
            while (seg.len > 0) {
                const n = @min(seg.len, LINE_CAP - self.line_len);
                @memcpy(self.line[self.line_len..][0..n], seg[0..n]);
                self.line_len += n;
                seg = seg[n..];
                const complete = self.line[self.line_len - 1] == '\n';
                if (complete or self.line_len == LINE_CAP) {
                    self.emitLine(self.line[0..self.line_len]);
                    self.line_len = 0;
                }
            }
        }
    }

    /// One complete (or cap-flushed) line: table rows buffer, everything
    /// else flushes any open table first and prints.
    fn emitLine(self: *RegionWriter, raw: []const u8) void {
        const body = if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
        if (self.table_alloc) |alloc| {
            if (isTableRow(body)) {
                const dup = alloc.dupe(u8, body) catch {
                    self.flushTableBlockLocked();
                    regionPrintLineLocked(self.real, raw);
                    return;
                };
                self.table_rows.append(alloc, dup) catch {
                    alloc.free(dup);
                    self.flushTableBlockLocked();
                    regionPrintLineLocked(self.real, raw);
                    return;
                };
                if (self.table_rows.items.len >= 64) self.flushTableBlockLocked(); // safety
                return;
            }
        }
        self.flushTableBlockLocked();
        regionPrintLineLocked(self.real, raw);
    }

    /// Emit the buffered table (if any) as one aligned block.
    pub fn flushTableBlock(self: *RegionWriter) void {
        ttyLock();
        defer ttyUnlock();
        self.flushTableBlockLocked();
        flushReal(self.real);
    }

    fn flushTableBlockLocked(self: *RegionWriter) void {
        if (self.table_rows.items.len == 0) return;
        const alloc = self.table_alloc orelse {
            self.table_rows.clearRetainingCapacity();
            return;
        };
        var out: std.ArrayList(u8) = .empty;
        renderTableBlock(alloc, self.table_rows.items, currentTermWidth(), &out) catch {
            out.deinit(alloc);
            for (self.table_rows.items) |r| regionPrintLineLocked(self.real, r);
            self.clearTableRows();
            return;
        };
        regionPrintLineLocked(self.real, out.items);
        out.deinit(alloc);
        self.clearTableRows();
    }

    fn clearTableRows(self: *RegionWriter) void {
        const alloc = self.table_alloc orelse {
            self.table_rows = .empty;
            return;
        };
        for (self.table_rows.items) |r| alloc.free(@constCast(r));
        self.table_rows.deinit(alloc);
        self.table_rows = .empty;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self = fromIface(w);
        ttyLock();
        defer ttyUnlock();
        var consumed: usize = 0;
        if (regionUp()) {
            for (data[0 .. data.len - 1]) |s| self.feedLocked(s);
            var i: usize = 0;
            while (i < splat) : (i += 1) self.feedLocked(data[data.len - 1]);
            for (data[0 .. data.len - 1]) |s| consumed += s.len;
            consumed += data[data.len - 1].len * splat;
            flushReal(self.real);
            return consumed;
        }
        // Region down: verbatim passthrough. Buffered table rows and a
        // partial line buffered while the region was up go out first so
        // ordering is preserved.
        self.flushTableBlockLocked();
        if (self.line_len > 0) {
            std.Io.Writer.writeAll(self.real, self.line[0..self.line_len]) catch return error.WriteFailed;
            self.line_len = 0;
        }
        for (data[0 .. data.len - 1]) |s| {
            try std.Io.Writer.writeAll(self.real, s);
            consumed += s.len;
        }
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            try std.Io.Writer.writeAll(self.real, data[data.len - 1]);
            consumed += data[data.len - 1].len;
        }
        return consumed;
    }

    /// Emit a buffered partial line (region up) — e.g. before the turn
    /// hands the bottom rows to a blocking interactive read. The REAL
    /// writer's flush stays the caller's job: the REPL flushes
    /// File.Writer explicitly at every print site, exactly as before.
    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self = fromIface(w);
        ttyLock();
        defer ttyUnlock();
        self.flushTableBlockLocked();
        if (self.line_len > 0 and regionUp()) {
            regionPrintLineLocked(self.real, self.line[0..self.line_len]);
            self.line_len = 0;
        }
    }
};

test "RegionWriter: line-atomic above the region, verbatim when down" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    resetPendingState();
    regionBegin(&aw.writer, "st");
    const drawn = aw.written().len;
    var rw = RegionWriter{ .real = &aw.writer };

    // A logical line split across THREE writes (the old leak shape:
    // "  [tool result: " + body + "]\n") must emit NOTHING until the
    // newline — a partial write into the region rows is exactly the
    // corruption this writer exists to prevent.
    try std.Io.Writer.writeAll(&rw.interface, "  [tool result: ");
    try std.Io.Writer.writeAll(&rw.interface, "abc");
    try std.testing.expectEqual(drawn, aw.written().len); // fully buffered
    try std.Io.Writer.print(&rw.interface, "]\n", .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "  [tool result: abc]\n") != null);
    // It printed INTO the transcript area via the FLOW protocol: DECRC
    // back to the flow position, relative write, DECSC re-save — the
    // pinned rows are never touched by transcript growth.
    try std.testing.expect(std.mem.indexOf(u8, aw.written()[drawn..], "\x1b8  [tool result: abc]\n\x1b7") != null);
    // print() through the unbuffered interface is chunk-safe too.
    try std.Io.Writer.print(&rw.interface, "x={d}\n", .{7});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "x=7\n") != null);

    // A partial line buffered while UP must come out in order once the
    // region drops, and post-drop writes pass through verbatim.
    try std.Io.Writer.writeAll(&rw.interface, "tail");
    regionEnd(&aw.writer);
    try std.Io.Writer.writeAll(&rw.interface, "+end\n");
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "tail+end\n") != null);
    const before_plain = aw.written().len;
    try std.Io.Writer.writeAll(&rw.interface, "plain\n");
    try std.testing.expectEqual(before_plain + "plain\n".len, aw.written().len);
}

test "regionFreeze keeps the summary row and frees the prompt row" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    resetPendingState();
    regionBegin(&aw.writer, "✓ 完成 · in 3 → out 4 · 1.5s");
    const drawn = aw.written().len;
    regionFreeze(&aw.writer);
    const out = aw.written()[drawn..];
    // The summary scrolled INTO the transcript as its last line (dim)…
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2m✓ 完成 · in 3 → out 4 · 1.5s\x1b[0m") != null);
    // …the scroll region reset and the pinned rows were erased.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[r") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[23;1H\x1b[2K") != null);
    try std.testing.expect(!regionUp());
}

/// Bracketed-paste state for the generation-period input path: a paste
/// during streaming feeds the editor as CONTENT (CR → newline, never
/// submit) instead of cancelling the generation the way a bare Esc does.
pub var paste_active: bool = false;

/// What a captured ESC-following sequence means.
const EscSeq = enum { cancel, paste_start, paste_end, newline };

fn classifyEscSeq(seq: []const u8) EscSeq {
    if (std.mem.eql(u8, seq, "[200~")) return .paste_start;
    if (std.mem.eql(u8, seq, "[201~")) return .paste_end;
    // Shift/Ctrl+Enter — legacy encoding (ESC then CR/LF, so `seq` is a
    // single "\r"/"\n") or kitty CSI-u ("13;<mods>u"). The editor inserts
    // a NEWLINE for these; the generation-period probe must do the SAME
    // into the pending buffer — classifying them as cancel killed the
    // turn and recalled the just-sent message the moment a supplement
    // went multi-line.
    if (seq.len == 1 and (seq[0] == '\r' or seq[0] == '\n')) return .newline;
    // `seq` includes the '[' introducer (captureEscSeq strips only the ESC).
    if (seq.len >= 4 and std.mem.startsWith(u8, seq, "[13;") and seq[seq.len - 1] == 'u') return .newline;
    return .cancel;
}

/// Capture the bytes following an ESC promptly (5ms per byte, `~`-styles
/// are 4-5 long). Returns the captured sequence WITHOUT the ESC. Checks
/// the reader's OWN buffer before polling the fd — a burst "ESC[200~…"
/// lands in ONE read and the kernel fd goes dry, so a poll-only loop
/// would see an empty sequence and misclassify.
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

/// Committed-style echo of a queued user message that has now ENTERED the
/// conversation (mid-turn injection or auto-send at turn end): the real
/// prompt prefix + magenta text, identical to a normally submitted line —
/// every user message looks alike in the transcript. Region-safe: prints
/// ABOVE the live region when it is up.
pub fn regionEchoCommitted(w: *std.Io.Writer, line: []const u8) void {
    var buf: [640]u8 = undefined;
    regionPrintLine(w, committedBuf(&buf, line));
}

/// Same echo at the cursor (region down — the auto-send path right after
/// a turn ended).
pub fn echoCommittedDirect(w: *std.Io.Writer, line: []const u8) void {
    var buf: [640]u8 = undefined;
    std.Io.Writer.writeAll(w, committedBuf(&buf, line)) catch {};
}

/// Build "<prompt><magenta>text<reset>\n" into buf; head-capped at a
/// UTF-8 boundary. buf must be >= prompt(<=192) + text cap(380) + escapes:
/// 640 keeps every write below the cap — a mid-write overflow would drop
/// the trailing SGR reset and bleed magenta into the transcript.
fn committedBuf(buf: []u8, line: []const u8) []const u8 {
    var f = std.Io.Writer.fixed(buf);
    std.Io.Writer.writeAll(&f, pendingPrompt()) catch return "\n";
    std.Io.Writer.writeAll(&f, "\x1b[1;35m") catch return "\n";
    var cut = @min(line.len, 380);
    while (cut > 0 and cut < line.len and (line[cut] & 0xC0) == 0x80) cut -= 1;
    std.Io.Writer.writeAll(&f, line[0..cut]) catch {};
    if (cut < line.len) std.Io.Writer.writeAll(&f, "…") catch {};
    std.Io.Writer.writeAll(&f, "\x1b[0m\n") catch {};
    return f.buffered();
}

/// ── P1: generation-period key pump ──────────────────────────────────
/// During a turn the SAME persistent editor handles keystrokes as the
/// prompt does — one identity, full editing capability (D2). Bytes come
/// from the stream callback's stdin drain and the provider stall waits
/// (waitSlice .input → liveSpoolPut). Enter queues the draft (existing
/// queue semantics); ONLY Esc/Ctrl-C cancel the generation (D4) —
/// editing keys can no longer kill a turn.
/// Bytes captured by the provider's stall wait (one at a time, ESC-led
/// sequences already resolved there): drained by editorLiveKey before
/// the reader.
pub var live_spool: [64]u8 = undefined;
pub var live_spool_len: usize = 0;

pub fn liveSpoolPut(b: u8) void {
    if (live_spool_len < live_spool.len) {
        live_spool[live_spool_len] = b;
        live_spool_len += 1;
    }
}

/// History walk shared by the prompt path and the live pump (D2 parity:
/// ↑/↓ during a generation browse history exactly like at the prompt).
fn editorHistoryUp(ed: *Editor) void {
    const history = ed.history orelse return;
    const alloc = ed.grow orelse return;
    if (ed.nav == null) {
        // A stale draft from an earlier navigation round (↓ back to
        // bottom, Ctrl-C) must be released before re-duping.
        if (ed.draft_owned) |d| {
            alloc.free(d);
            ed.draft_owned = null;
        }
        ed.draft_owned = alloc.dupe(u8, ed.buf[0..ed.len]) catch null;
        ed.nav = history.items.len;
    }
    if (ed.nav.? > 0) {
        ed.nav.? -= 1;
        ed.loadHistory(history.items[ed.nav.?]);
        ed.browsing = true;
    }
}

fn editorHistoryDown(ed: *Editor) void {
    const history = ed.history orelse return;
    if (ed.nav == null) return;
    if (ed.nav.? + 1 < history.items.len) {
        ed.nav.? += 1;
        ed.loadHistory(history.items[ed.nav.?]);
    } else {
        ed.nav = null;
        if (ed.draft_owned) |d| ed.loadHistory(d);
        ed.browsing = false;
    }
}

/// Apply one classified CSI body (without ESC/[) to the editor.
/// Returns false when the sequence is NOT an editing key (caller treats
/// it as a cancel — e.g. kitty CSI 27u = the Esc key).
fn liveCsiEdit(ed: *Editor, body: []const u8) bool {
    switch (classifyCsi(body)) {
        .right => {
            if (ed.pos < ed.len) ed.pos = nextChar(ed.buf[0..ed.len], ed.pos);
        },
        .left => {
            if (ed.pos > 0) ed.pos = prevChar(ed.buf[0..ed.len], ed.pos);
        },
        .up => {
            if (std.mem.indexOfScalar(u8, ed.buf[0..ed.len], '\n') != null) {
                if (moveVertically(ed.buf[0..ed.len], ed.pos, -1)) |np| ed.pos = np;
            } else editorHistoryUp(ed);
        },
        .down => {
            if (std.mem.indexOfScalar(u8, ed.buf[0..ed.len], '\n') != null) {
                if (moveVertically(ed.buf[0..ed.len], ed.pos, 1)) |np| ed.pos = np;
            } else editorHistoryDown(ed);
        },
        .home => ed.pos = 0,
        .end => ed.pos = ed.len,
        .delete => ed.deleteAt(),
        .newline => ed.insertBytes("\n") catch {},
        .ctrl => {
            // Reuse the prompt's ctrl bindings where they edit; Ctrl-R
            // search is prompt-only (its UI owns extra rows), Ctrl-C is
            // handled by the caller as cancel.
            const b = ctrlLetterByte(body) orelse return true;
            switch (b) {
                0x01 => ed.pos = 0,
                0x05 => ed.pos = ed.len,
                0x02 => {
                    if (ed.pos > 0) ed.pos = prevGlyph(ed.buf[0..ed.len], ed.pos);
                },
                0x06 => {
                    if (ed.pos < ed.len) ed.pos = nextGlyph(ed.buf[0..ed.len], ed.pos);
                },
                0x17 => ed.deleteWordBack(),
                0x15 => ed.deleteToStart(),
                0x0b => ed.deleteToEnd(),
                0x04 => ed.deleteAt(),
                else => {}, // 0x12 (Ctrl-R) and friends: ignored live
            }
        },
        .esc => return false,
        .ignore => {},
        .paste_start => {}, // unreachable live: paste mode is handled upstream
    }
    return true;
}

/// Enter during a generation: queue the editor's draft as a message
/// (mid-turn injection / auto-send at turn end — unchanged semantics),
/// then reset the draft. Confirmation flashes in the STATUS row.
fn liveQueueSubmit(ed: *Editor, w: ?*std.Io.Writer) bool {
    if (ed.len == 0) return false;
    if (queued_count >= QUEUED_MAX) return false;
    const alloc = ed.grow orelse return false;
    const line = ed.takeLine(alloc) catch return false;
    defer alloc.free(line);
    const n = @min(line.len, QUEUED_CAP);
    @memcpy(queued_msgs[queued_count][0..n], line[0..n]);
    queued_lens[queued_count] = n;
    queued_echoed[queued_count] = w != null;
    queued_count += 1;
    if (w) |ww| {
        // VISIBILITY (the "排队+1 啥也看不见" fix): the queued message
        // echoes into the TRANSCRIPT immediately — committed-style, with
        // a dim queue marker — so the user sees WHAT they sent, not a
        // counter. Injection/auto-send skip their own echo (the flag).
        var buf: [768]u8 = undefined;
        var f = std.Io.Writer.fixed(&buf);
        std.Io.Writer.writeAll(&f, pendingPrompt()) catch {};
        std.Io.Writer.writeAll(&f, "\x1b[1;35m") catch {};
        var cut = @min(line.len, 380);
        while (cut > 0 and cut < line.len and (line[cut] & 0xC0) == 0x80) cut -= 1;
        std.Io.Writer.writeAll(&f, line[0..cut]) catch {};
        if (cut < line.len) std.Io.Writer.writeAll(&f, "…") catch {};
        std.Io.Writer.writeAll(&f, "\x1b[0m\x1b[2m ↳ 已排队\x1b[0m\n") catch {};
        // Echo + status repaint under ONE hold (review ① 2026-11-06): the
        // old shape called locked regionPrintLine, released, then painted
        // the status row UNLOCKED — the exact DECSC-clobber interleave the
        // tty mutex exists to kill, reachable on every mid-turn Enter.
        ttyLock();
        regionPrintLineLocked(ww, f.buffered());
        var sb: [96]u8 = undefined;
        const st = std.fmt.bufPrint(&sb, "↳ 已排队 {d} 条 · 本轮生效或回合后自动发送", .{queuedCount()}) catch "";
        pendingStatusSet(st);
        if (pending_shown) {
            if (termHeight() != region_h) {
                regionApply(ww);
            } else {
                paintStatusRow(ww);
            }
        }
        flushReal(ww);
        ttyUnlock();
    }
    return true;
}

/// Drain every available keystroke into the persistent editor. Returns
/// true when the user cancelled the generation (Esc / Ctrl-C). `w` null
/// in drain contexts — capture without echo.
pub fn editorLiveKey(r: *std.Io.Reader, w: ?*std.Io.Writer) bool {
    const ed = live_ed orelse return false;
    while (true) {
        var c: u8 = undefined;
        if (live_spool_len > 0) {
            c = live_spool[0];
            live_spool_len -= 1;
            std.mem.copyForwards(u8, live_spool[0..live_spool_len], live_spool[1 .. live_spool_len + 1]);
        } else {
            if (r.bufferedLen() == 0) {
                var pfd = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
                if (std.c.poll(&pfd, 1, 0) != 1 or (pfd[0].revents & std.c.POLL.IN) == 0) return false;
            }
            c = r.takeByte() catch return false;
        }
        if (paste_active) {
            // Paste content (no folding live: pills need the whole body
            // staged at once; the prompt path folds). CR becomes a newline
            // so a multi-line paste is ONE message; other control bytes
            // drop. Markers arrive byte-wise through this same drain.
            if (c == 0x1b) {
                const seq = captureEscSeq(r);
                const sl = std.mem.sliceTo(&seq, 0);
                if (classifyEscSeq(sl) == .paste_end) {
                    paste_active = false;
                    if (w) |ww| renderPendingLine(ww);
                    continue;
                }
                ed.insertBytes("\x1b") catch {};
                for (seq) |b| {
                    if (b == 0) break;
                    ed.insertBytes(&.{b}) catch {};
                }
                continue;
            }
            if (c == '\r') {
                ed.insertBytes("\n") catch {};
            } else if (c >= 0x20 or c == '\n' or c == '\t') {
                ed.insertBytes(&.{c}) catch {};
            }
            if (w) |ww| renderPendingLine(ww);
            continue;
        }
        if (c == 0x03) {
            // Ctrl-C cancels like Esc; swallow an immediately-following
            // second press so it cannot leak into the next prompt.
            var p2 = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&p2, 1, 5) == 1 and (p2[0].revents & std.c.POLL.IN) != 0) {
                _ = r.takeByte() catch {};
            }
            return true;
        }
        if (c != 0x1b) {
            if (c == 0x0F) {
                // Ctrl+O: tool-output verbosity toggle (works mid-turn and
                // at the prompt — one muscle memory everywhere).
                if (on_verbose_toggle) |cb| {
                    if (w) |ww| regionPrintLine(ww, cb()); // self-locking
                }
                if (w) |ww| renderPendingLine(ww);
                continue;
            }
            if (c == '\r') {
                _ = liveQueueSubmit(ed, w);
            } else if (c == 0x7f or c == 0x08) {
                ed.backspace();
                ed.browsing = false;
            } else if (c >= 0x20 or c == '\n') {
                ed.insertBytes(&.{c}) catch {};
                ed.browsing = false;
            }
            if (w) |ww| renderPendingLine(ww);
            continue;
        }
        // ESC: classify what follows. Editing CSIs edit; newline inserts;
        // only a REAL Esc key cancels (D4).
        const seq = captureEscSeq(r);
        const sl = std.mem.sliceTo(&seq, 0);
        switch (classifyEscSeq(sl)) {
            .paste_start => paste_active = true,
            .paste_end => {},
            .newline => ed.insertBytes("\n") catch {},
            .cancel => {
                if (sl.len == 0) return true; // lone Esc
                if (!liveCsiEdit(ed, sl[1..])) return true; // CSI 27u etc.
            },
        }
        if (w) |ww| renderPendingLine(ww);
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
    /// ── P1 (tui-event-loop): session-shared editor state ──
    /// The editor instance now outlives a single readLine call (the
    /// generation-period key pump drives the SAME buffer), so navigation
    /// state moves from readLine locals into the editor where both key
    /// sources see it.
    history: ?*std.ArrayList([]u8) = null,
    nav: ?usize = null, // history index while navigating
    draft_owned: ?[]u8 = null, // pre-navigation draft (heap: line may be long)

    /// Free every folded-paste slot (buffer markers referencing them die
    /// with the buffer content they annotated).
    fn releaseSlots(self: *Editor) void {
        const g = self.grow orelse {
            self.pastes = @splat(null);
            return;
        };
        for (&self.pastes) |*ps| {
            if (ps.*) |d| g.free(d.data);
            ps.* = null;
        }
    }

    /// Reset to a fresh empty draft: submit/queue handoff. Paste slots
    /// were expanded into the taken line; nav/draft state ends with the
    /// draft that used it.
    pub fn clearForNewDraft(self: *Editor) void {
        self.len = 0;
        self.pos = 0;
        self.browsing = false;
        self.nav = null;
        if (self.draft_owned) |d| {
            if (self.grow) |g| g.free(d);
            self.draft_owned = null;
        }
        self.releaseSlots();
        self.last_rows = 0;
        self.park_row = 0;
    }

    /// Expand folded pastes, return the line as a fresh allocation, and
    /// leave the editor as an empty draft. Null on allocation failure
    /// (editor keeps its content — the caller may retry).
    pub fn takeLine(self: *Editor, alloc: std.mem.Allocator) ![]u8 {
        var exp: ?[]u8 = null;
        if (std.mem.indexOfScalar(u8, self.buf[0..self.len], 0) != null) {
            exp = expandPasted(alloc, self.buf[0..self.len], &self.pastes) catch null;
        }
        const line = exp orelse try alloc.dupe(u8, self.buf[0..self.len]);
        self.clearForNewDraft();
        return line;
    }

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
        // The replaced buffer may have carried paste markers — their slots
        // are unreachable now; free them (expanded history text never has
        // markers, so this only drops the live draft's pills).
        self.releaseSlots();
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
/// fd 0 is a terminal? (Raw mode itself is owned by the SESSION guard in
/// repl.run — scoping it per-prompt left every mid-turn keystroke to the
/// cooked line discipline, which echoed control keys as ^[[C/^R garbage
/// and line-buffered input the editor never saw until Enter.)
fn stdinIsTty() bool {
    var t: std.c.termios = undefined;
    return std.c.tcgetattr(0, &t) == 0;
}

/// The session RawGuard (repl.run), for Ctrl-Z's manual suspend: restore
/// cooked while stopped, re-enter raw on resume. Null in tests/pipe mode.
var session_guard: ?*menu.RawGuard = null;

pub fn setSessionGuard(g: *menu.RawGuard) void {
    session_guard = g;
}

pub fn readLine(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    prompt: []const u8,
    history: *std.ArrayList([]u8),
    alloc: std.mem.Allocator,
) !?[]u8 {
    if (!stdinIsTty() and !force_editor) {
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

    // P1: the persistent session editor — the first call lazily creates
    // it; every later readLine AND the generation-period key pump
    // (editorLiveKey) reuse the SAME buffer. A draft typed mid-generation
    // simply IS the draft the next prompt opens with — no handoff, no
    // typeahead merge. IO handles re-bind per call (identical in
    // production; keeps tests independent).
    if (live_ed == null) {
        const initial = try alloc.alloc(u8, 8192);
        live_ed_buf = initial;
        const created = try alloc.create(Editor);
        created.* = .{
            .w = w,
            .file_writer = file_writer,
            .r = r,
            .prompt = prompt,
            .buf = initial,
            .grow = alloc,
            .owned_buf = initial,
        };
        live_ed = created;
    }
    const ed = live_ed.?;
    ed.w = w;
    ed.file_writer = file_writer;
    ed.r = r;
    ed.prompt = prompt;
    ed.grow = alloc;
    ed.history = history;

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

        if (c == 0x0F) {
            // Ctrl+O: same verbosity toggle at the prompt level.
            // regionPrintLine takes tty_mu itself — an outer lock here
            // self-deadlocks (Io.Mutex is NOT reentrant; found live).
            if (on_verbose_toggle) |cb| {
                regionPrintLine(w, cb());
            }
            ed.render() catch {};
            continue;
        }

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
                    if (ed.nav == null) {
                        // A stale draft from an earlier navigation round
                        // (↓ back to bottom, Ctrl-C) must be released before
                        // re-duping — overwriting the pointer leaked it.
                        if (ed.draft_owned) |d| {
                            alloc.free(d);
                            ed.draft_owned = null;
                        }
                        ed.draft_owned = alloc.dupe(u8, ed.buf[0..ed.len]) catch null;
                        ed.nav = history.items.len;
                    }
                    if (ed.nav.? > 0) {
                        ed.nav.? -= 1;
                        ed.loadHistory(history.items[ed.nav.?]);
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
                    if (ed.nav == null) continue;
                    if (ed.nav.? + 1 < history.items.len) {
                        ed.nav.? += 1;
                        ed.loadHistory(history.items[ed.nav.?]);
                    } else {
                        ed.nav = null;
                        if (ed.draft_owned) |d| ed.loadHistory(d);
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
                    // P1: takeLine expands folded pastes, hands the line
                    // out as its own allocation, and leaves the persistent
                    // editor as a fresh empty draft. On OOM the editor
                    // KEEPS its content — show it again and let the user
                    // retry (the session survives).
                    const line = ed.takeLine(alloc) catch {
                        try ed.render();
                        continue;
                    };
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
                    return line; // caller frees; the editor already reset
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
                ed.nav = null;
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
                if (session_guard) |g| {
                    if (g.active) {
                        g.restore();
                        const dfl_tstp: std.posix.Sigaction = .{
                            .handler = .{ .handler = @ptrFromInt(0) },
                            .mask = std.posix.sigemptyset(),
                            .flags = 0,
                        };
                        std.posix.sigaction(.TSTP, &dfl_tstp, null);
                        std.posix.raise(.TSTP) catch {};
                        g.enterNoSig();
                    }
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

// ── P1: generation-period key pump tests ──

/// Full test reset: region flags, queue, spool, paste state, and the
/// persistent editor's draft (slots/draft freed through its grow
/// allocator — testing.allocator leak checks stay honest).
fn resetPendingState() void {
    live_spool_len = 0;
    paste_active = false;
    pending_shown = false;
    pending_status_shown = false;
    queued_count = 0;
    queued_read = 0;
    @memset(&queued_lens, 0);
    if (live_ed) |ed| ed.clearForNewDraft();
}

/// Create the persistent editor for pump tests (no reader interaction
/// needed beyond Reader.fixed drains).
fn editorEnsure(alloc: std.mem.Allocator, w: *std.Io.Writer, r: *std.Io.Reader, prompt: []const u8) *Editor {
    if (live_ed) |ed| {
        ed.w = w;
        ed.r = r;
        ed.prompt = prompt;
        ed.grow = alloc;
        return ed;
    }
    const initial = alloc.alloc(u8, 8192) catch @panic("OOM");
    live_ed_buf = initial;
    const created = alloc.create(Editor) catch @panic("OOM");
    created.* = .{
        .w = w,
        .file_writer = undefined,
        .r = r,
        .prompt = prompt,
        .buf = initial,
        .grow = alloc,
        .owned_buf = initial,
    };
    live_ed = created;
    return created;
}

test "editorLiveKey: typing edits the draft, Enter queues it FIFO" {
    const alloc = std.testing.allocator;
    defer editorDeinit(alloc);
    resetPendingState();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var fr0 = std.Io.Reader.fixed("");
    const ed = editorEnsure(alloc, &aw.writer, &fr0, "> ");
    var fr = std.Io.Reader.fixed("abc");
    ed.r = &fr;
    try std.testing.expect(!editorLiveKey(&fr, null));
    try std.testing.expectEqualStrings("abc", ed.buf[0..ed.len]);

    // Enter (queued submit): the draft MOVES into the queue and the
    // editor resets — Enter during a generation is 排队, not prompt submit.
    var fr_enter = std.Io.Reader.fixed("\r");
    ed.r = &fr_enter;
    try std.testing.expect(!editorLiveKey(&fr_enter, null));
    try std.testing.expectEqual(@as(usize, 1), queued_count);
    try std.testing.expectEqualStrings("abc", queued_msgs[0][0..queued_lens[0]]);
    try std.testing.expectEqual(@as(usize, 0), ed.len); // draft reset

    // CJK + backspace-rune + queue: same semantics as the prompt editor.
    var fr2 = std.Io.Reader.fixed("\u{4E2D}\u{6587}x\x7f\x7f\r");
    ed.r = &fr2;
    try std.testing.expect(!editorLiveKey(&fr2, null));
    try std.testing.expectEqual(@as(usize, 2), queued_count);
    try std.testing.expectEqualStrings("\u{4E2D}", queued_msgs[1][0..queued_lens[1]]);
}

test "editorLiveKey: arrows EDIT, lone Esc cancels, Shift+Enter newlines" {
    const alloc = std.testing.allocator;
    defer editorDeinit(alloc);
    resetPendingState();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var fr = std.Io.Reader.fixed("ab\x1b[D");
    const ed = editorEnsure(alloc, &aw.writer, &fr, "> ");
    try std.testing.expect(!editorLiveKey(&fr, null));
    try std.testing.expectEqualStrings("ab", ed.buf[0..ed.len]);
    try std.testing.expectEqual(@as(usize, 1), ed.pos); // Left moved the cursor

    // Shift+Enter (legacy ESC+CR): newline AT THE CURSOR (full editor
    // semantics — the cursor sits after 'a'), NOT a cancel.
    var fr2 = std.Io.Reader.fixed("\x1b\r");
    ed.r = &fr2;
    try std.testing.expect(!editorLiveKey(&fr2, null));
    try std.testing.expectEqualStrings("a\nb", ed.buf[0..ed.len]);

    // Lone Esc (nothing follows within the 5ms capture): cancels.
    var fr3 = std.Io.Reader.fixed("\x1b");
    ed.r = &fr3;
    try std.testing.expect(editorLiveKey(&fr3, null));
}

test "editorLiveKey: paste feeds the draft as content, CR queues it" {
    const alloc = std.testing.allocator;
    defer editorDeinit(alloc);
    resetPendingState();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const burst = "\x1b[200~hello paste\x1b[201~\r";
    var fr = std.Io.Reader.fixed(burst);
    const ed = editorEnsure(alloc, &aw.writer, &fr, "> ");
    try std.testing.expect(!editorLiveKey(&fr, null)); // paste must NOT cancel
    try std.testing.expectEqualStrings("hello paste", queued_msgs[0][0..queued_lens[0]]);
    try std.testing.expectEqual(@as(usize, 0), ed.len);
    try std.testing.expect(!paste_active);
}

test "editorLiveKey: queue submit confirms via status row, not transcript" {
    const alloc = std.testing.allocator;
    defer editorDeinit(alloc);
    resetPendingState();
    defer resetPendingState();
    regionPromptSet("> ");
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    regionBegin(&aw.writer, "⏳ 等待响应 1.0s");
    aw.clearRetainingCapacity();
    var fr = std.Io.Reader.fixed("note\r");
    const ed = editorEnsure(alloc, &aw.writer, &fr, "> ");
    try std.testing.expect(!editorLiveKey(&fr, &aw.writer));
    // The confirmation flashed into the ABSOLUTE status row (DECSTBM
    // protocol: status is a pinned row, not a transcript line).
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[23;1H\x1b[2K\x1b[2m↳ 已排队 1 条") != null);
    try std.testing.expectEqual(@as(usize, 0), ed.len);
}

test "esc sequence classification: paste markers vs cancel" {
    try std.testing.expect(classifyEscSeq("[200~") == .paste_start);
    try std.testing.expect(classifyEscSeq("[201~") == .paste_end);
    try std.testing.expect(classifyEscSeq("[A") == .cancel);
    try std.testing.expect(classifyEscSeq("") == .cancel);
}

test "live region: DECSTBM split, pinned rows, transcript scrolls in region" {
    const alloc = std.testing.allocator;
    defer editorDeinit(alloc);
    resetPendingState();
    defer resetPendingState();
    force_width = 100;
    defer force_width = 0;
    force_height = 24;
    defer force_height = 0;
    regionPromptSet("ziv (m) [10%] > ");

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;

    // Turn start: scroll region splits the screen (rows 1..22 transcript,
    // 23 status, 24 input); the input row carries the REAL prompt prefix.
    regionBegin(w, "⏳ 等待响应 0.0s");
    const begin_out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, begin_out, "\x1b[1;22r") != null);
    try std.testing.expect(std.mem.indexOf(u8, begin_out, "\x1b[23;1H\x1b[2K\x1b[2m⏳ 等待响应 0.0s") != null);
    try std.testing.expect(std.mem.indexOf(u8, begin_out, "\x1b[24;1H\x1b[2Kziv (m) [10%] > ") != null);
    try std.testing.expect(std.mem.indexOf(u8, begin_out, "⌨") == null);

    // Keystrokes through the persistent editor: ONLY the input row
    // repaints (absolute) — status and transcript untouched.
    aw.clearRetainingCapacity();
    var fr = std.Io.Reader.fixed("hi");
    const ed = editorEnsure(alloc, w, &fr, "ziv (m) [10%] > ");
    try std.testing.expect(!editorLiveKey(&fr, w));
    const typed = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, typed, "\x1b[24;1H\x1b[2Kziv (m) [10%] > hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed, "⏳") == null); // no status repaint
    _ = ed;

    // Transcript line: DECRC to the flow position + RELATIVE write + DECSC
    // re-save — content grows downward from wherever it is (no bottom
    // jump, no gap); the pinned rows are never cleared or repainted for
    // transcript growth.
    aw.clearRetainingCapacity();
    regionPrintLine(w, "  response line 1\n");
    const printed = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, printed, "\x1b8  response line 1\n\x1b7") != null);
    try std.testing.expect(std.mem.count(u8, printed, "\x1b[2K") == 0); // no row erasing
    try std.testing.expect(std.mem.indexOf(u8, printed, "ziv (m) [10%] > hi") == null); // input row not redrawn

    // Status tick (P3c 心跳自愈): status row AND the editor block repaint —
    // any transient wipe of the pinned input row self-heals within one
    // 500ms tick (2026-11-07: the "input area disappears after send"
    // report's root strategy).
    aw.clearRetainingCapacity();
    regionStatus(w, "⏳ 本轮 1.2s");
    const ticked = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, ticked, "\x1b[23;1H\x1b[2K\x1b[2m⏳ 本轮 1.2s") != null);
    // Editor block DID repaint (self-heal contract).
    try std.testing.expect(std.mem.indexOf(u8, ticked, "\x1b[24;1H\x1b[2K") != null);

    // Turn end: scroll region reset, pinned rows erased, region down.
    aw.clearRetainingCapacity();
    regionEnd(w);
    const ended = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, ended, "\x1b[r") != null);
    try std.testing.expect(std.mem.count(u8, ended, "\x1b[2K") == 2); // two pinned rows
    try std.testing.expect(!regionUp());
}

test "live region: multi-line draft renders as a full editor block (P3b)" {
    const alloc = std.testing.allocator;
    defer editorDeinit(alloc);
    resetPendingState();
    defer resetPendingState();
    force_width = 100;
    defer force_width = 0;
    force_height = 24;
    defer force_height = 0;
    regionPromptSet("> ");

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    regionBegin(&aw.writer, "st");

    // Three logical lines: block grows to 3 rows → split moves to 20.
    var fr = std.Io.Reader.fixed("a\nb\nc");
    const ed = editorEnsure(alloc, &aw.writer, &fr, "> ");
    try std.testing.expect(!editorLiveKey(&fr, &aw.writer));
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;20r") != null); // DECSTBM re-split
    // Each logical line paints its own absolute pinned row (22..24;
    // 21 is the status row).
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[22;1H\x1b[2K> a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[23;1H\x1b[2Kb") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[24;1H\x1b[2Kc") != null);
    _ = ed;
}

test "live region: slash commands keep their colors in the pinned input row (P3c)" {
    const alloc = std.testing.allocator;
    defer editorDeinit(alloc);
    resetPendingState();
    defer resetPendingState();
    force_width = 100;
    defer force_width = 0;
    force_height = 24;
    defer force_height = 0;
    regionPromptSet("> ");

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    regionBegin(&aw.writer, "st");

    // Type a KNOWN command mid-turn: the pinned input row must paint it
    // cyan, exactly like the prompt-level editor (the regression behind
    // "回合中 /指令没有颜色").
    var fr = std.Io.Reader.fixed("/stats");
    const ed = editorEnsure(alloc, &aw.writer, &fr, "> ");
    _ = editorLiveKey(&fr, &aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[36m/stats\x1b[0m") != null);
    _ = ed;
}

test "markdown table renders aligned and width-clipped" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    resetPendingState();
    defer resetPendingState();
    force_width = 80;
    defer force_width = 0;
    regionBegin(&aw.writer, "st");

    var rw = RegionWriter{ .real = &aw.writer, .table_alloc = alloc };
    // A CJK table: columns must align by DISPLAY width (板块 = 4 cols,
    // 一、常用底层算法 = 18) — the renderer pads every cell to its
    // column's width so the pipes form straight columns.
    const tbl = " | 板块 | 计划 | 已完成 |\n |---|---|---|\n | 一、常用底层算法 | 55 | **55** |\n | 二、LLM 算法 | 100 | **25** |\ndone\n";
    try std.Io.Writer.writeAll(&rw.interface, tbl);
    rw.flushTableBlock();

    // Collect the rendered table lines (start with '|').
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, aw.written(), '\n');
    while (it.next()) |ln| {
        var t2 = std.mem.trimStart(u8, ln, "\x1b8");
        t2 = std.mem.trimStart(u8, t2, "\x1b[2m");
        if (std.mem.startsWith(u8, t2, "|")) try lines.append(alloc, ln);
    }
    // The header row is glued to the region-arming control sequence (no
    // newline between them), so the per-line collection sees rule + 2
    // body rows; the header is asserted as a substring directly.
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b8| 板块") != null);
    // THE invariant: pipe byte-offsets identical across the data rows
    // (padding aligned the columns).
    // Pipe positions in DISPLAY columns (CJK = 2): alignment is a
    // display property — byte offsets differ when CJK/ASCII mix.
    const pipeCols = struct {
        fn of(line: []const u8, buf: *[32]usize) usize {
            var n: usize = 0;
            var col: usize = 0;
            var i: usize = 0;
            while (i < line.len) {
                const next = nextChar(line, i);
                if (line[i] == '|') {
                    if (n < buf.len) {
                        buf[n] = col;
                        n += 1;
                    }
                }
                col += strWidth(line[i..next]);
                i = next;
            }
            return n;
        }
    };
    // Reference = the FIRST data row (the rule line only has 2 pipes).
    var ref: [32]usize = undefined;
    const ref_n = pipeCols.of(lines.items[1], &ref);
    for (lines.items[2..]) |ln| {
        var cur: [32]usize = undefined;
        const cur_n = pipeCols.of(ln, &cur);
        try std.testing.expectEqual(ref_n, cur_n);
        try std.testing.expectEqualSlices(usize, ref[0..ref_n], cur[0..cur_n]);
    }
    // Separator rendered as a rule line, post-table text intact.
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\u{2500}") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "done") != null);
}

test "over-wide table clips to terminal width" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    resetPendingState();
    defer resetPendingState();
    force_width = 40; // narrow terminal
    defer force_width = 0;
    regionBegin(&aw.writer, "st");

    var rw = RegionWriter{ .real = &aw.writer, .table_alloc = alloc };
    const long = "01234567890123456789012345678901234567890123456789";
    try std.Io.Writer.print(&rw.interface, " | {s} | b |\n |---|---|\n | {s} | c |\ntail\n", .{ long, long });
    rw.flushTableBlock();
    const out = aw.written();
    // No rendered row may exceed the width budget: clipped cells end
    // with the ellipsis.
    try std.testing.expect(std.mem.indexOf(u8, out, "…") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tail\n") != null);
}

test "RegionWriter renders streamed markdown tables, not raw pipes" {
    // The 2026-11-06 wiring regression this locks: model text streams in
    // as margin-seeded lines through the RegionWriter — pipe tables must
    // come out as aligned blocks with a rule line, never raw |---|.
    // drain() gates the table path on regionUp(); tests have no live
    // region, so enter one step down at feed() — the exact function the
    // region-up branch dispatches to. Same-file access keeps the seam
    // private.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &out);
    var rw = RegionWriter{ .real = &aw.writer, .table_alloc = std.testing.allocator };
    rw.feed(" | 节奏 | 完成时间 |\n|---|---|\n| 每天 1 轮 | ~27 天 |\nplain line\n");
    out = aw.toArrayList();
    const s = out.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "|---|") == null); // raw separator gone
    try std.testing.expect(std.mem.indexOf(u8, s, "\u{2500}") != null); // rule line rendered
    try std.testing.expect(std.mem.indexOf(u8, s, "节奏") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "plain line") != null);
}

// ── Phase 0 lock tests (tui-event-loop plan) ─────────────────────────
// End-to-end readLine through a REAL Io (Threaded) + /dev/null
// File.Writer + Reader.fixed input. These lock the behaviors the event-
// loop refactor must preserve verbatim; assertions here must survive
// every later phase (call shape may change, behavior may not).

/// Shared rig for one readLine call. `input` is the byte stream the
/// "user" produces.
const ReadRig = struct {
    io_state: std.Io.Threaded,
    devnull: std.Io.File,
    fw_buf: [64]u8 = undefined,
    fw: std.Io.File.Writer,
    aw: std.Io.Writer.Allocating,
    fr: std.Io.Reader,
    history: std.ArrayList([]u8) = .empty,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, input: []const u8) !ReadRig {
        var io_state = std.Io.Threaded.init(alloc, .{});
        const devnull = try std.Io.Dir.openFileAbsolute(io_state.io(), "/dev/null", .{ .mode = .write_only });
        var rig = ReadRig{
            .io_state = io_state,
            .devnull = devnull,
            .fw = undefined,
            .aw = .init(alloc),
            .fr = std.Io.Reader.fixed(input),
            .alloc = alloc,
        };
        rig.fw = std.Io.File.Writer.initStreaming(rig.devnull, rig.io_state.io(), &rig.fw_buf);
        return rig;
    }

    fn deinit(self: *ReadRig) void {
        editorDeinit(self.alloc);
        self.devnull.close(self.io_state.io());
        self.io_state.deinit();
        for (self.history.items) |h| self.alloc.free(h);
        self.history.deinit(self.alloc);
        self.aw.deinit();
    }

    fn call(self: *ReadRig) !?[]u8 {
        force_editor = true;
        defer force_editor = false;
        return readLine(&self.aw.writer, &self.fr, &self.fw, "> ", &self.history, self.alloc);
    }
};

test "readLine e2e: multi-line via Shift+Enter CSI-u, Enter submits" {
    const alloc = std.testing.allocator;
    var rig = try ReadRig.init(alloc, "line1\x1b[13;2uline2\r");
    defer rig.deinit();
    const line = (try rig.call()).?;
    defer alloc.free(line);
    try std.testing.expectEqualStrings("line1\nline2", line);
    // Committed echo shows the multi-line body (the typed block is erased
    // on submit — the echo is its only trace).
    try std.testing.expect(std.mem.indexOf(u8, rig.aw.written(), "line1\nline2") != null);
}

test "readLine e2e: big paste folds to a pill, submit expands it back" {
    const alloc = std.testing.allocator;
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(alloc);
    for (0..12) |i| {
        if (i > 0) try blob.append(alloc, '\n');
        try blob.appendSlice(alloc, "paste line");
    }
    const input = try std.fmt.allocPrint(alloc, "\x1b[200~{s}\x1b[201~\r", .{blob.items});
    defer alloc.free(input);

    var rig = try ReadRig.init(alloc, input);
    defer rig.deinit();
    const line = (try rig.call()).?;
    defer alloc.free(line);
    // The model must receive the EXACT bytes an unfolded paste would have
    // produced — markers expanded, all 12 lines intact.
    try std.testing.expectEqualStrings(blob.items, line);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, 0) == null); // no marker bytes
}

test "readLine e2e: up-arrow recalls the previous submission" {
    // Two readLine calls share one history list; each gets its own Io
    // lifetime (Threaded Io is not re-initiable inside one rig).
    try runSecondRecall(std.testing.allocator);
}

fn runSecondRecall(alloc: std.mem.Allocator) !void {
    var history: std.ArrayList([]u8) = .empty;
    defer {
        for (history.items) |h| alloc.free(h);
        history.deinit(alloc);
    }
    {
        var rig = try ReadRig.init(alloc, "first input\r");
        defer rig.deinit();
        rig.history = history; // readLine appends into THIS list
        const l = (try rig.call()).?;
        alloc.free(l);
        history = rig.history;
        rig.history = .empty; // ownership moved out — deinit must not touch it
    }
    {
        var rig = try ReadRig.init(alloc, "\x1b[A\r");
        defer rig.deinit();
        rig.history = history;
        const l = (try rig.call()).?;
        defer alloc.free(l);
        try std.testing.expectEqualStrings("first input", l);
        history = rig.history;
        rig.history = .empty;
    }
}

test "readLine non-TTY: byte-compat line read, overlong truncated not EOF" {
    const alloc = std.testing.allocator;
    var history: std.ArrayList([]u8) = .empty;
    defer history.deinit(alloc);
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const devnull = try std.Io.Dir.openFileAbsolute(io_state.io(), "/dev/null", .{ .mode = .write_only });
    defer devnull.close(io_state.io());
    var fw_buf: [64]u8 = undefined;
    var fw = std.Io.File.Writer.initStreaming(devnull, io_state.io(), &fw_buf);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    // force_editor stays false and stdin is not a TTY under the test
    // runner → the pipe-compatible path, byte-for-byte like the old one.
    var fr = std.Io.Reader.fixed("hello pipe\nJUNK");
    const l = try readLine(&aw.writer, &fr, &fw, "> ", &history, alloc);
    defer alloc.free(l.?);
    try std.testing.expectEqualStrings("hello pipe", l.?);

    // Overlong: truncated to the fixed 4096, returns a line (NOT null —
    // the old code mistook WriteFailed for EOF and said Goodbye).
    const big = try alloc.alloc(u8, 5000);
    defer alloc.free(big);
    @memset(big, 'x');
    big[4999] = '\n';
    var fr2 = std.Io.Reader.fixed(big);
    const l2 = try readLine(&aw.writer, &fr2, &fw, "> ", &history, alloc);
    defer alloc.free(l2.?);
    try std.testing.expect(l2.?.len == 4096);
}

test "editorLiveKey: Shift+Enter during generation is a newline, not a cancel" {
    const alloc = std.testing.allocator;
    defer editorDeinit(alloc);
    resetPendingState();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var fr = std.Io.Reader.fixed("\x1b\r");
    const ed = editorEnsure(alloc, &aw.writer, &fr, "> ");
    try std.testing.expect(!editorLiveKey(&fr, null));
    try std.testing.expectEqualStrings("\n", ed.buf[0..ed.len]);
}
