//! @文件引用（M7/T7.1，2026-11-19）：输入行里的 `@path[:a[-b]]` token
//! 在 REPL 层展开——文件内容（行域可选；≤200 行/16 KiB 截断）作为随行
//! `<system-reminder>` user 消息注入（与 attachment 通知同语义：不触发
//! 回合）。扫描放 REPL 而非 lineinput——编辑器无 fs 意识，且 auto_submit
//! 排队路径也要覆盖（都在 readLine 返回之后、消息入史之前这一拍）。
//! @ 引用是只读喂料，与 FileRead 同级不设询问（CC 同款）。

const std = @import("std");

pub const MAX_LINES: usize = 200;
pub const MAX_BYTES: usize = 16 * 1024;

pub const AtRef = struct {
    path: []const u8, // owned（alloc）
    start: usize = 1, // 1-based 含端
    end: usize = 0, // 0 = 至文件末尾
};

/// 纯扫描：空白分隔 token，@ 开头（`@@` 整体忽略——邮箱/装饰性）；
/// 语法 `@path`、`@path:10`、`@path:10-50`（end<start 交换；负数/垃圾
/// 后缀 → 降级为整文件）。路径不可为空。
pub fn scan(alloc: std.mem.Allocator, text: []const u8) ![]AtRef {
    var refs = std.ArrayList(AtRef).empty;
    errdefer refs.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| {
        if (tok.len < 2 or tok[0] != '@') continue;
        if (tok[1] == '@') continue;
        const body = tok[1..];
        // 行域：第一个 ':' 之后（Windows 盘符路径在这个工具语境不常见，
        // 取首个冒号——与 CC @file:10-50 语法一致）。
        var path = body;
        var start: usize = 1;
        var end: usize = 0;
        if (std.mem.indexOfScalar(u8, body, ':')) |ci| {
            path = body[0..ci];
            const range = body[ci + 1 ..];
            var rit = std.mem.splitSequence(u8, range, "-");
            const a = rit.next() orelse "";
            const b = rit.next();
            if (std.fmt.parseInt(usize, a, 10)) |n| {
                start = if (n == 0) 1 else n;
            } else |_| {
                // 垃圾行域：降级整文件（path 已切好）
            }
            if (b) |bs| {
                if (bs.len > 0) {
                    if (std.fmt.parseInt(usize, bs, 10)) |n| end = n else |_| {}
                }
            }
            if (end != 0 and end < start) {
                const t = start;
                start = end;
                end = t;
            }
        }
        if (path.len == 0) continue;
        try refs.append(alloc, .{ .path = try alloc.dupe(u8, path), .start = start, .end = end });
    }
    return refs.toOwnedSlice(alloc);
}

/// 读取并合并渲染全部 ref 为单帧 system-reminder 文本（null = 无 ref）。
/// 读不动的 ref 标注错误行，不中断其余。返回文本 alloc 持有（调用方
/// 随消息入史后移交 history；refs 的 path 由本函数释放）。
pub fn renderRefs(alloc: std.mem.Allocator, io: std.Io, input_text: []const u8) ?[]u8 {
    const refs = scan(alloc, input_text) catch return null;
    defer {
        for (refs) |r| alloc.free(r.path);
        alloc.free(refs);
    }
    if (refs.len == 0) return null;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("<system-reminder>\n") catch return null;
    for (refs) |r| {
        renderOne(alloc, io, w, r) catch |err| {
            // 复审 🟢7：「太大」不是「读不动」——分型标注，模型才知道
            // 该改行域（@path:1-100）而不是放弃这个文件。
            if (err == error.FileTooLarge) {
                w.print("<file {s}: 文件过大（≥{d} KiB 读取上限），已跳过——可指定行域重试，如 @{s}:1-100>\n", .{ r.path, 4 * MAX_BYTES / 1024, r.path }) catch return null;
            } else {
                w.print("<file {s}: 读取失败，已跳过>\n", .{r.path}) catch return null;
            }
        };
    }
    w.writeAll("</system-reminder>") catch return null;
    return alloc.dupe(u8, w.buffered()) catch null;
}

fn renderOne(alloc: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, r: AtRef) !void {
    const text = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, r.path, alloc, .limited(4 * MAX_BYTES)) catch |read_err| {
        // StreamTooLong 单列（.limited 语义：达到/超过上限即抛）——
        // 上层据此标注「文件过大」而非误导性的「读取失败」。
        if (read_err == error.StreamTooLong) return error.FileTooLarge;
        return read_err;
    };
    defer alloc.free(text);

    // 行切分 + 行域过滤 + 双帽截断（行数与字节，先截后写——头部标注
    // 反映最终展示量）。
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(alloc);
    var truncated = false;
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        var idx: usize = 0;
        var total: usize = 0;
        while (it.next()) |line| {
            idx += 1;
            if (idx < r.start) continue;
            if (r.end != 0 and idx > r.end) break;
            if (lines.items.len >= MAX_LINES or total + line.len > MAX_BYTES) {
                truncated = true;
                break;
            }
            total += line.len;
            try lines.append(alloc, line);
        }
    }

    try w.print("<file {s}", .{r.path});
    if (r.start > 1 or r.end != 0) {
        try w.print(" lines {d}", .{r.start});
        if (r.end != 0) try w.print("-{d}", .{r.end}) else try w.print("-", .{});
    }
    try w.print(" ({d} lines shown", .{lines.items.len});
    if (truncated) try w.print(", truncated at {d} lines/{d} KiB cap", .{ lines.items.len, MAX_BYTES / 1024 });
    try w.writeAll("):\n");
    for (lines.items) |l| try w.print("{s}\n", .{l});
}

test "T7.1 scan: plain, line ranges, swap, degrade, ignores @@ and bare @" {
    const alloc = std.testing.allocator;
    const refs = try scan(alloc, "look at @src/a.zig and @b.md:10 plus @c.txt:50-20");
    defer {
        for (refs) |r| alloc.free(r.path);
        alloc.free(refs);
    }
    try std.testing.expectEqual(@as(usize, 3), refs.len);
    try std.testing.expectEqualStrings("src/a.zig", refs[0].path);
    try std.testing.expectEqual(@as(usize, 1), refs[0].start);
    try std.testing.expectEqual(@as(usize, 0), refs[0].end);
    try std.testing.expectEqualStrings("b.md", refs[1].path);
    try std.testing.expectEqual(@as(usize, 10), refs[1].start);
    try std.testing.expectEqual(@as(usize, 0), refs[1].end); // 开区间 → 至末尾
    try std.testing.expectEqualStrings("c.txt", refs[2].path);
    try std.testing.expectEqual(@as(usize, 20), refs[2].start); // 交换
    try std.testing.expectEqual(@as(usize, 50), refs[2].end);

    const none = try scan(alloc, "no refs here @@decorative @");
    defer {
        for (none) |r| alloc.free(r.path);
        alloc.free(none);
    }
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "T7.1 renderRefs: missing file degrades to note, no refs → null" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();
    try std.testing.expect(renderRefs(alloc, io, "plain text") == null);
    const frame = renderRefs(alloc, io, "see @/definitely/not/a/file.zig") orelse return error.NoFrame;
    defer alloc.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "<system-reminder>") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "读取失败") != null);

    // 复审 🟢7：≥64 KiB 的文件标注「文件过大」（StreamTooLong 分型），
    // 不再误报「读取失败」；并给出行域重试提示。
    const big_path = ".zig-cache/t71-big.txt";
    const big = try alloc.alloc(u8, 4 * MAX_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'x');
    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = big_path, .data = big }) catch return error.TestSetup;
    defer std.Io.Dir.cwd().deleteFile(io, big_path) catch {};
    const big_ref = try std.fmt.allocPrint(alloc, "see @{s}", .{big_path});
    defer alloc.free(big_ref);
    const frame2 = renderRefs(alloc, io, big_ref) orelse return error.NoFrame;
    defer alloc.free(frame2);
    try std.testing.expect(std.mem.indexOf(u8, frame2, "文件过大") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame2, "读取失败") == null);
}
