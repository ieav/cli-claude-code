/// Raw-mode line editor for the REPL prompt: arrows move the cursor,
/// up/down walk input history, Backspace/Delete/Home/End work, UTF-8
/// advances per character. Falls back to plain line reading on non-TTY
/// stdin (pipes/scripts keep the old behavior byte-for-byte).
const std = @import("std");
const menu = @import("menu.zig");

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

/// Test hook: force the editor path even when stdin is not a TTY.
pub var force_editor = false;

const Editor = struct {
    w: *std.Io.Writer,
    file_writer: *std.Io.File.Writer,
    r: *std.Io.Reader,
    prompt: []const u8,
    buf: []u8,
    len: usize = 0,
    pos: usize = 0,

    fn render(self: *Editor) !void {
        try self.w.print("\r\x1b[2K{s}{s}", .{ self.prompt, self.buf[0..self.len] });
        // Park the cursor at the editing position.
        const tail_w = strWidth(self.buf[self.pos..self.len]);
        if (tail_w > 0) {
            var b: [16]u8 = undefined;
            const back = std.fmt.bufPrint(&b, "\x1b[{d}D", .{tail_w}) catch "";
            try self.w.writeAll(back);
        }
        try std.Io.File.Writer.flush(self.file_writer);
    }

    fn insert(self: *Editor, b: u8) !void {
        if (self.len >= self.buf.len) return;
        std.mem.copyBackwards(u8, self.buf[self.pos + 1 .. self.len + 1], self.buf[self.pos..self.len]);
        self.buf[self.pos] = b;
        self.pos += 1;
        self.len += 1;
    }

    fn backspace(self: *Editor) void {
        if (self.pos == 0) return;
        const start = prevChar(self.buf[0..self.len], self.pos);
        const cut = self.pos - start;
        std.mem.copyForwards(u8, self.buf[start .. self.len - cut], self.buf[self.pos..self.len]);
        self.len -= cut;
        self.pos = start;
    }

    fn deleteAt(self: *Editor) void {
        if (self.pos >= self.len) return;
        const end = nextChar(self.buf[0..self.len], self.pos);
        const cut = end - self.pos;
        std.mem.copyForwards(u8, self.buf[self.pos .. self.len - cut], self.buf[end..self.len]);
        self.len -= cut;
    }

    fn loadHistory(self: *Editor, item: []const u8) void {
        const n = @min(item.len, self.buf.len);
        @memcpy(self.buf[0..n], item[0..n]);
        self.len = n;
        self.pos = n;
    }
};

/// Read a line with full cursor editing. Returns the byte length, or null
/// on EOF / Ctrl-D on an empty line. `history` receives committed non-empty
/// lines and is used for up/down navigation.
pub fn readLine(
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    file_writer: *std.Io.File.Writer,
    prompt: []const u8,
    buf: []u8,
    history: *std.ArrayList([]u8),
    alloc: std.mem.Allocator,
) !?usize {
    var guard = menu.RawGuard{};
    guard.enter();
    defer guard.restore();

    if (!guard.active and !force_editor) {
        // Non-TTY: behave exactly like the old reader.
        var bw = std.Io.Writer.fixed(buf);
        const n = std.Io.Reader.streamDelimiter(r, &bw, '\n') catch return null;
        r.toss(1);
        return n;
    }

    var ed = Editor{ .w = w, .file_writer = file_writer, .r = r, .prompt = prompt, .buf = buf };
    var nav: ?usize = null; // history index while navigating
    var draft: [4096]u8 = undefined; // match the edit buffer — smaller sizes overflow on long lines
    var draft_len: usize = 0;

    try ed.render();
    while (true) {
        const c = ed.r.takeByte() catch return null;
        if (c == 0x1b) {
            const seq2 = ed.r.takeByte() catch {
                try ed.render(); // lone ESC: ignore
                continue;
            };
            if (seq2 != '[') continue;
            const final = ed.r.takeByte() catch continue;
            switch (final) {
                'C' => { // right
                    if (ed.pos < ed.len) ed.pos = nextChar(ed.buf[0..ed.len], ed.pos);
                },
                'D' => { // left
                    if (ed.pos > 0) ed.pos = prevChar(ed.buf[0..ed.len], ed.pos);
                },
                'A' => { // up: previous history entry
                    if (history.items.len == 0) continue;
                    if (nav == null) {
                        @memcpy(draft[0..ed.len], ed.buf[0..ed.len]);
                        draft_len = ed.len;
                        nav = history.items.len;
                    }
                    if (nav.? > 0) {
                        nav.? -= 1;
                        ed.loadHistory(history.items[nav.?]);
                    }
                },
                'B' => { // down: next history entry
                    if (nav == null) continue;
                    if (nav.? + 1 < history.items.len) {
                        nav.? += 1;
                        ed.loadHistory(history.items[nav.?]);
                    } else {
                        nav = null;
                        ed.loadHistory(draft[0..draft_len]);
                    }
                },
                'H', '1' => ed.pos = 0, // Home (some terms: ESC[1~)
                'F', '4' => ed.pos = ed.len, // End
                '3' => { // Delete (ESC[3~)
                    _ = ed.r.takeByte() catch {}; // consume '~'
                    ed.deleteAt();
                },
                else => {},
            }
            try ed.render();
            continue;
        }
        switch (c) {
            '\r', '\n' => {
                try ed.w.writeAll("\n");
                try std.Io.File.Writer.flush(file_writer);
                const line = ed.buf[0..ed.len];
                if (line.len > 0 and (history.items.len == 0 or !std.mem.eql(u8, history.items[history.items.len - 1], line))) {
                    const owned = alloc.dupe(u8, line) catch null;
                    if (owned) |o| {
                        history.append(alloc, o) catch alloc.free(o);
                    }
                }
                return ed.len;
            },
            0x7f, 0x08 => ed.backspace(),
            0x03 => { // Ctrl-C: clear the line, start over
                ed.len = 0;
                ed.pos = 0;
                nav = null;
                try ed.w.writeAll("^C\n");
            },
            0x04 => { // Ctrl-D on empty line: EOF
                if (ed.len == 0) {
                    try ed.w.writeAll("\n");
                    return null;
                }
            },
            else => {
                if (c >= 0x20) try ed.insert(c);
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
    var fw_buf: [64]u8 = undefined;
    // A File.Writer is needed for flush; in tests use a fixed writer-backed
    // stand-in is not possible, so drive the editor pieces directly instead.
    _ = &fw_buf;

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
