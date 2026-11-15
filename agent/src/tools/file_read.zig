/// FileRead tool — reads file contents with line numbers.
/// Repeat reads of an unchanged file are served from the process-wide
/// FileStateCache (validated by mtime+size): no disk IO, no per-line
/// formatting, and one shared allocation per unique read instead of one
/// per line.
const std = @import("std");
const wincompat = @import("../util/wincompat.zig");
const registry = @import("registry.zig");
const file_cache = @import("../util/file_cache.zig");
const code_index = @import("../knowledge/code_index.zig");

/// 2026-11-15 fix #2（多文件准确度）：全量读的行帽与两条路径共用的字节
/// 帽。此前全量读会把 ≤1 MiB 的文件整份格式化，再被历史层静默砍到
/// 4096 字节——模型不知道文件还有后半段，基于残缺视图编辑。现在帽子
/// 落在本工具内并附带续读标记；字节帽留出余量，使「内容 + 标记」稳
/// 稳落在 registry.HISTORY_OUTPUT_CAP（16 KiB）之下，历史层的标记对
/// FileRead 永不重复触发。
pub const DEFAULT_LINE_CAP: usize = 400;
pub const SLICE_BYTE_CAP: usize = 15 * 1024;

/// RCA 链 A 修复（2026-11-15）：二进制嗅探——首 8 KiB 内出现 NUL 即判
/// 二进制（ripgrep 同规则）。原先 .png/.db/.class 原样按行编号进上下
/// 文，15 KiB 预算换零理解价值（writeJsonString 的 U+FFFD 清洗只保请
/// 求不炸，模型看到的仍是乱码）。改为一次可教学的失败：报错并指路。
/// UTF-16 文本会误中（ASCII 字符的 NUL 高位）——可接受：它以文本形态
/// 呈现同样是乱码。
fn looksBinary(contents: []const u8) bool {
    const scan = @min(contents.len, 8 * 1024);
    for (contents[0..scan]) |c| {
        if (c == 0) return true;
    }
    return false;
}

// ── 会话读迹注册表（RCA 链 B5，2026-11-15 阅读理解衰减）──
// 「读过什么」比「读到什么」死得快：折叠/瘦身后模型连文件名都不剩。
// 注册表按 path 去重记录 path + 真实总行数（32 条环形），REPL 在每个提
// 示符快照冻结、随 F1 尾注入请求——模型全程知道本会话读过哪些文件、
// 各多少行，重读是一次零 IO 调用（FileStateCache）。并行 FileRead 安全
//（自旋锁，临界区是 memcpy 级）。
const RF_RING: usize = 32;
const RF_PATH: usize = 512;
const ReadEntry = struct { path: [RF_PATH]u8, path_len: u16, lines: u32 };
var rf_mu: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var rf_ring: [RF_RING]ReadEntry = undefined;
var rf_head: usize = 0;
var rf_count: usize = 0;

fn rfLock() void {
    while (rf_mu.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
fn rfUnlock() void {
    rf_mu.store(false, .release);
}

/// 成功读取后登记（按 path 去重、行数就地更新；不改变环内位置——
/// 首读顺序即清单顺序，足够）。
pub fn noteFileRead(path: []const u8, total_lines: usize) void {
    const plen = @min(path.len, RF_PATH);
    rfLock();
    defer rfUnlock();
    for (rf_ring[0..rf_count]) |*e| {
        if (e.path_len == plen and std.mem.eql(u8, e.path[0..e.path_len], path[0..plen])) {
            e.lines = @intCast(@min(total_lines, std.math.maxInt(u32)));
            return;
        }
    }
    const slot = &rf_ring[rf_head];
    @memcpy(slot.path[0..plen], path[0..plen]);
    slot.path_len = @intCast(plen);
    slot.lines = @intCast(@min(total_lines, std.math.maxInt(u32)));
    rf_head = (rf_head + 1) % RF_RING;
    rf_count = @min(rf_count + 1, RF_RING);
}

/// 读迹文本（新→旧，`- path (N lines)` 行）。无记录 → null；调用方拥有
/// 返回串。
pub fn readFilesText(alloc: std.mem.Allocator) ?[]u8 {
    rfLock();
    defer rfUnlock();
    if (rf_count == 0) return null;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    var i: usize = 0;
    while (i < rf_count) : (i += 1) {
        const idx = (rf_head + RF_RING - 1 - i) % RF_RING;
        const e = &rf_ring[idx];
        aw.writer.print("- {s} ({d} lines)\n", .{ e.path[0..e.path_len], e.lines }) catch break;
    }
    var list = aw.toArrayList();
    return list.toOwnedSlice(alloc) catch null;
}

/// 测试隔离用：清空注册表。
pub fn readFilesReset() void {
    rfLock();
    defer rfUnlock();
    rf_head = 0;
    rf_count = 0;
}

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const path = getStringField(input, "path") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Error: 'path' field is required") catch "", .is_error = true };

    const max_size: usize = 1024 * 1024;

    // Sliced read (offset/limit): the schema advertises it and the model
    // uses it to pull just the relevant window of a big file — the #1
    // context-efficiency lever. Slices bypass the FileStateCache (entries
    // are keyed by path only; a slice would poison a full-read entry and
    // vice versa).
    const opt_offset = getIntField(input, "offset");
    const opt_limit = getIntField(input, "limit");
    if (opt_offset != null or opt_limit != null) {
        return readSlice(alloc, io, path, opt_offset, opt_limit, max_size);
    }

    // Cache hit: unchanged since the last read — hand back a copy of the
    // formatted content the cache owns.
    if (file_cache.global) |*cache| {
        if (cache.getFresh(io, path)) |cached| {
            return registry.ToolResult{ .output = try alloc.dupe(u8, cached) };
        }
    }

    // Stat feeds the cache's freshness key; a failed stat just means the
    // result won't be cached (st = null).
    const st: ?std.Io.Dir.Stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch null;

    const contents = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, std.Io.Limit.limited(max_size)) catch |err| {
        const msg = alloc.print("Failed to read '{s}': {}", .{ path, err }) catch return error.OutOfMemory;
        return registry.ToolResult{ .output = msg, .is_error = true };
    };
    defer alloc.free(contents);

    // RCA 链 A（2026-11-15）：二进制拒读——在索引落库与格式化之前，
    // 垃圾既不进上下文也不进 code index。
    if (looksBinary(contents)) {
        const msg = try alloc.print("Binary file ({d} bytes): {s} — not readable as text. Locate content with Grep, or extract strings via Bash: strings {s}", .{ contents.len, path, path });
        return registry.ToolResult{ .output = msg, .is_error = true };
    }

    // P6: deposit the successful read into the code index (before the raw
    // buffer is freed) — literal Grep queries then serve from .ziv/index.db
    // instead of spawning rg. Best-effort: index failure never fails the read.
    if (st) |s| {
        code_index.upsertFile(alloc, io, path, @intCast(s.mtime.nanoseconds), @intCast(s.size), contents);
    }

    // Format with line numbers, capped (fix #2): the continuation marker
    // names the file's real line count so the model knows where to page.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const capped = writeCappedLines(&aw, contents, 1, DEFAULT_LINE_CAP, SLICE_BYTE_CAP);
    if (capped.shown > 0 and capped.shown < capped.total) {
        aw.writer.print("(showing lines 1-{d} of {d}; pass offset={d} to continue)\n", .{ capped.shown, capped.total, capped.shown + 1 }) catch {};
    }
    // B5：登记读迹（真实总行数——即使只展示了帽内部分）。
    noteFileRead(path, capped.total);

    var formatted = aw.toArrayList();
    const formatted_slice = try formatted.toOwnedSlice(alloc);

    // Populate the cache for the next read (copies both strings).
    if (file_cache.global) |*cache| {
        if (st) |s| {
            cache.put(io, path, formatted_slice, s.mtime.nanoseconds, s.size) catch {};
        }
    }

    return registry.ToolResult{ .output = formatted_slice };
}

/// Capped line formatter shared by the full-read and slice paths.
/// Formats lines from `start_line` (1-based) with `{d:6}\t` numbering into
/// `aw`, stopping after `max_lines` shown lines or once `max_bytes` of
/// formatted output is reached (at least one line always shows, so a
/// single huge line still surfaces — the history layer's own cap+marker
/// covers that tail). Returns shown/total; the caller appends the
/// continuation marker when shown < total.
fn writeCappedLines(aw: *std.Io.Writer.Allocating, contents: []const u8, start_line: usize, max_lines: usize, max_bytes: usize) struct { shown: usize, total: usize } {
    // True line count: newlines + 1, minus the trailing-newline artifact
    // ("a\nb\n" is 2 lines, "a\nb" is 2 too, "" is 0).
    const total: usize = if (contents.len == 0)
        0
    else
        std.mem.count(u8, contents, "\n") + @intFromBool(contents[contents.len - 1] != '\n');
    var line_num: usize = 1;
    var shown: usize = 0;
    var it = std.mem.splitSequence(u8, contents, "\n");
    while (it.next()) |line| : (line_num += 1) {
        // line_num > total: the split artifact after a trailing newline.
        if (line_num > total) break;
        if (line_num < start_line) continue;
        if (shown >= max_lines) break;
        // +16 covers the "{d:6}\t" prefix and "\n"; check between lines so
        // the cut stays line-atomic (from the 2nd shown line on).
        if (shown > 0 and aw.written().len + line.len + 16 > max_bytes) break;
        aw.writer.print("{d:6}\t{s}\n", .{ line_num, line }) catch break;
        shown += 1;
    }
    return .{ .shown = shown, .total = total };
}

fn getStringField(input: std.json.Value, key: []const u8) ?[]const u8 {
    if (input != .object) return null;
    const obj = input.object.get(key) orelse return null;
    if (obj != .string) return null;
    return obj.string;
}

fn getIntField(input: std.json.Value, key: []const u8) ?usize {
    if (input != .object) return null;
    const v = input.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// offset = 1-based starting line (inclusive), limit = max line count.
/// Either may be absent (offset defaults to 1, limit to "rest of file").
/// The tail marker names the file's real line count so the model knows
/// whether (and where) to page next — a silent truncation used to send
/// it re-reading the whole file. An explicit limit is honored up to the
/// shared byte cap (fix #2): past it the same continuation marker fires,
/// so an oversized slice request degrades honestly instead of feeding
/// the history layer a silent cut.
fn readSlice(alloc: std.mem.Allocator, io: std.Io, path: []const u8, opt_offset: ?usize, opt_limit: ?usize, max_size: usize) !registry.ToolResult {
    const start_line: usize = if (opt_offset) |o| @max(o, 1) else 1;
    const contents = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, std.Io.Limit.limited(max_size)) catch |err| {
        const msg = alloc.print("Failed to read '{s}': {}", .{ path, err }) catch return error.OutOfMemory;
        return registry.ToolResult{ .output = msg, .is_error = true };
    };
    defer alloc.free(contents);
    if (looksBinary(contents)) {
        const msg = try alloc.print("Binary file ({d} bytes): {s} — not readable as text. Locate content with Grep, or extract strings via Bash: strings {s}", .{ contents.len, path, path });
        return registry.ToolResult{ .output = msg, .is_error = true };
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const pw = &aw.writer;
    const limit: usize = opt_limit orelse std.math.maxInt(usize);
    const capped = writeCappedLines(&aw, contents, start_line, limit, SLICE_BYTE_CAP);
    const total_lines = capped.total;
    const shown = capped.shown;
    // B5：切片读同样登记（同一 path 去重、行数更新）。
    noteFileRead(path, total_lines);
    if (start_line > total_lines) {
        const msg = try alloc.print("offset {d} is past the end of the file (it has {d} lines)", .{ start_line, total_lines });
        return registry.ToolResult{ .output = msg, .is_error = true };
    }
    if (start_line + shown <= total_lines and shown > 0) {
        pw.print("(showing lines {d}-{d} of {d}; pass offset={d} to continue)", .{ start_line, start_line + shown - 1, total_lines, start_line + shown }) catch {};
    }
    var formatted = aw.toArrayList();
    return registry.ToolResult{ .output = try formatted.toOwnedSlice(alloc) };
}

fn sleepMs(ms: u32) void {
    wincompat.sleepMs(ms);
}

test "FileRead offset/limit slices with accurate totals" {
    defer code_index.closeGlobal();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const tmp = "/tmp/ziv_fileread_slice_test.txt";
    // 10 lines, trailing newline.
    var body_aw: std.Io.Writer.Allocating = .init(alloc);
    for (1..11) |i| try body_aw.writer.print("line{d}\n", .{i});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = body_aw.written() });
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    file_cache.globalInit(std.testing.allocator);
    defer file_cache.deinitGlobal();

    const mk = struct {
        fn call(a: std.mem.Allocator, offset: ?i64, limit: ?i64) std.json.Value {
            var obj: std.json.ObjectMap = .empty;
            obj.put(a, "path", .{ .string = "/tmp/ziv_fileread_slice_test.txt" }) catch unreachable;
            if (offset) |o| obj.put(a, "offset", .{ .integer = o }) catch unreachable;
            if (limit) |l| obj.put(a, "limit", .{ .integer = l }) catch unreachable;
            return .{ .object = obj };
        }
    }.call;

    // offset=3, limit=2 → lines 3-4 + continuation marker.
    const r1 = try execute(alloc, mk(alloc, 3, 2), io);
    try std.testing.expect(!r1.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "     3\tline3") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "     4\tline4") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "     5\t") == null); // not shown
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "offset=5 to continue") != null);

    // Whole-file slice by limit only → lines 1..N, no marker beyond end.
    const r2 = try execute(alloc, mk(alloc, null, 100), io);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "    10\tline10") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "to continue") == null); // covered everything

    // Past the end → explicit error naming the real count.
    const r3 = try execute(alloc, mk(alloc, 11, null), io);
    try std.testing.expect(r3.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r3.output, "it has 10 lines") != null);
}

test "FileRead whole-file read caps at DEFAULT_LINE_CAP with a continuation marker" {
    defer code_index.closeGlobal();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const tmp = "/tmp/ziv_fileread_cap_test.txt";
    var body_aw: std.Io.Writer.Allocating = .init(alloc);
    for (1..1001) |i| try body_aw.writer.print("line{d}\n", .{i});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = body_aw.written() });
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    file_cache.globalInit(std.testing.allocator);
    defer file_cache.deinitGlobal();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "path", .{ .string = tmp });
    const r = try execute(alloc, .{ .object = obj }, io);
    // Exactly the cap's lines shown, plus a marker naming the true total
    // and the next offset — never a silent cut.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "  400\tline400") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "  401\t") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "showing lines 1-400 of 1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "pass offset=401 to continue") != null);
    // The whole capped output (content + marker) must fit the history cap
    // so the history layer's own marker never double-fires for FileRead.
    try std.testing.expect(r.output.len < registry.HISTORY_OUTPUT_CAP);
    // Slicing continues where the cap stopped.
    var sobj: std.json.ObjectMap = .empty;
    try sobj.put(alloc, "path", .{ .string = tmp });
    try sobj.put(alloc, "offset", .{ .integer = 401 });
    try sobj.put(alloc, "limit", .{ .integer = 2 });
    const rs = try execute(alloc, .{ .object = sobj }, io);
    try std.testing.expect(std.mem.indexOf(u8, rs.output, "  401\tline401") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs.output, "  402\tline402") != null);
}

test "FileRead byte cap trumps an oversized explicit limit, honestly" {
    defer code_index.closeGlobal();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const tmp = "/tmp/ziv_fileread_bytecap_test.txt";
    var body_aw: std.Io.Writer.Allocating = .init(alloc);
    // 600 lines × ~40 chars ≈ 24 KiB formatted — over SLICE_BYTE_CAP but
    // under the 400-line cap, so the byte cap is the binding one.
    for (1..601) |i| try body_aw.writer.print("padding-content-line-number-{d:04}-xxxxxxxx\n", .{i});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = body_aw.written() });
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "path", .{ .string = tmp });
    try obj.put(alloc, "limit", .{ .integer = 5000 }); // absurd ask
    const r = try execute(alloc, .{ .object = obj }, io);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "to continue") != null);
    try std.testing.expect(r.output.len < registry.HISTORY_OUTPUT_CAP);
}

test "FileRead refuses binary files with a teaching error (RCA A)" {
    defer code_index.closeGlobal();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const tmp = "/tmp/ziv_fileread_binary_test.bin";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = "PK\x00\x03\x04rest-of-archive" });
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "path", .{ .string = tmp });
    const r = try execute(alloc, .{ .object = obj }, io);
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Binary file") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "strings") != null); // 取回路径在文案里

    // 切片路径同门（NUL 在首 8KiB 内）。
    var sobj: std.json.ObjectMap = .empty;
    try sobj.put(alloc, "path", .{ .string = tmp });
    try sobj.put(alloc, "offset", .{ .integer = 1 });
    const rs = try execute(alloc, .{ .object = sobj }, io);
    try std.testing.expect(rs.is_error);
    try std.testing.expect(std.mem.indexOf(u8, rs.output, "Binary file") != null);
}

test "reading registry: ring wraps at 32, oldest evicted (B5)" {
    readFilesReset();
    defer readFilesReset();
    var i: usize = 0;
    while (i < 34) : (i += 1) {
        var pb: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "/tmp/f{d}.zig", .{i}) catch unreachable;
        noteFileRead(p, i + 1);
    }
    const t = (readFilesText(std.testing.allocator)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(t);
    // 最旧两条(0、1)被挤出;最新在首行;恰 32 条。
    try std.testing.expect(std.mem.indexOf(u8, t, "/tmp/f0.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "/tmp/f1.zig") == null);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, t, "\n"), "- /tmp/f33.zig"));
    try std.testing.expect(std.mem.indexOf(u8, t, "/tmp/f2.zig") != null);
    try std.testing.expectEqual(@as(usize, 32), std.mem.count(u8, t, "\n"));
}

test "reading registry: note, dedupe-by-path, render newest-first (B5)" {
    readFilesReset();
    defer readFilesReset();
    noteFileRead("/tmp/a.zig", 100);
    noteFileRead("/tmp/b.zig", 200);
    noteFileRead("/tmp/a.zig", 150); // 去重：就地更新行数
    const t = (readFilesText(std.testing.allocator)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(t);
    const b_at = std.mem.indexOf(u8, t, "- /tmp/b.zig (200 lines)");
    const a_at = std.mem.indexOf(u8, t, "- /tmp/a.zig (150 lines)");
    try std.testing.expect(b_at != null and a_at != null);
    try std.testing.expect(b_at.? < a_at.?); // 新→旧
    try std.testing.expect(std.mem.indexOf(u8, t, "(100 lines)") == null); // 旧行数已更新
    // 空注册表 → null。
    readFilesReset();
    try std.testing.expect(readFilesText(std.testing.allocator) == null);
}

test "FileRead formats with line numbers and caches repeats" {
    defer code_index.closeGlobal(); // the read deposits into the lazily-opened index
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const tmp = "/tmp/ziv_fileread_cache_test.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = "alpha\nbeta\n" });
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    file_cache.globalInit(alloc);
    defer file_cache.deinitGlobal();

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(alloc);
    try obj.put(alloc, "path", .{ .string = tmp });

    // First read: formats and populates the cache.
    const r1 = try execute(alloc, .{ .object = obj }, io);
    defer alloc.free(r1.output);
    try std.testing.expect(!r1.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "     1\talpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "     2\tbeta") != null);

    // Rewrite the file (new mtime) → second read must NOT serve the cache.
    sleepMs(20);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = "gamma\n" });
    const r2 = try execute(alloc, .{ .object = obj }, io);
    defer alloc.free(r2.output);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "gamma") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "alpha") == null);
}
