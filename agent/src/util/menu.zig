/// Interactive arrow-key menu for the REPL (raw terminal mode).
/// Keys: arrow up/down or vim k/j to move, Enter to select, q/Esc to cancel,
/// digits 1-9 to jump. Falls back to plain byte reading when stdin is not
/// a TTY (pipes/tests) so the same escape sequences still work.
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

/// Read one logical key; ESC [ A/B are arrow up/down, a lone ESC is quit.
pub fn readKey(r: *std.Io.Reader) !Key {
    const c = r.takeByte() catch |err| {
        if (err == error.EndOfStream) return .quit;
        return err;
    };
    if (c != 0x1b) return parseKey(c);
    const next = r.takeByte() catch return .quit;
    if (next != '[') return .quit;
    const final = r.takeByte() catch return .quit;
    return switch (final) {
        'A' => .up,
        'B' => .down,
        else => .ignore, // left/right/Home/etc unused
    };
}

const RawGuard = struct {
    orig: std.c.termios = undefined,
    active: bool = false,

    fn enter(self: *RawGuard) void {
        if (std.c.tcgetattr(0, &self.orig) != 0) return; // not a TTY (pipe)
        var raw = self.orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[@backingInt(std.c.V.MIN)] = 1;
        raw.cc[@backingInt(std.c.V.TIME)] = 0;
        if (std.c.tcsetattr(0, .NOW, &raw) == 0) self.active = true;
    }

    fn restore(self: *RawGuard) void {
        if (self.active) _ = std.c.tcsetattr(0, .NOW, &self.orig);
    }
};

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
    try w.writeAll("  ↑↓/jk 移动 · Enter 确认 · q 取消\n");
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
    var guard = RawGuard{};
    guard.enter();
    defer guard.restore();

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
            .ignore => {},
        }
        try render(w, title, items, idx);
        try std.Io.File.Writer.flush(file_writer);
    }
}

/// Read one line of text (cooked mode restored first) — for entering values
/// after a menu selection.
pub fn readLine(r: *std.Io.Reader, w: *std.Io.Writer, file_writer: *std.Io.File.Writer, prompt: []const u8, buf: []u8) ![]const u8 {
    try w.print("{s}", .{prompt});
    try std.Io.File.Writer.flush(file_writer);
    var bw = std.Io.Writer.fixed(buf);
    const n = std.Io.Reader.streamDelimiter(r, &bw, '\n') catch return "";
    r.toss(1);
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

test "parseKey mappings" {
    try std.testing.expect(parseKey('\r') == .enter);
    try std.testing.expect(parseKey('\n') == .enter);
    try std.testing.expect(parseKey('q') == .quit);
    try std.testing.expect(parseKey('k') == .up);
    try std.testing.expect(parseKey('j') == .down);
    const k = parseKey('2');
    try std.testing.expect(k == .digit);
    try std.testing.expect(k.digit == 1);
    try std.testing.expect(parseKey('x') == .ignore);
    try std.testing.expect(parseKey(0x1b) == .quit);
}
