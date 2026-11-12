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

    // P6: deposit the successful read into the code index (before the raw
    // buffer is freed) — literal Grep queries then serve from .ziv/index.db
    // instead of spawning rg. Best-effort: index failure never fails the read.
    if (st) |s| {
        code_index.upsertFile(alloc, io, path, @intCast(s.mtime.nanoseconds), @intCast(s.size), contents);
    }

    // Format with line numbers — one allocating writer for the whole pass
    // (the old loop allocated and freed one string per line).
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const pw = &aw.writer;
    var line_num: usize = 1;
    var iter = std.mem.splitSequence(u8, contents, "\n");
    while (iter.next()) |line| : (line_num += 1) {
        pw.print("{d:6}\t{s}\n", .{ line_num, line }) catch break;
    }
    alloc.free(contents);

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
/// it re-reading the whole file.
fn readSlice(alloc: std.mem.Allocator, io: std.Io, path: []const u8, opt_offset: ?usize, opt_limit: ?usize, max_size: usize) !registry.ToolResult {
    const start_line: usize = if (opt_offset) |o| @max(o, 1) else 1;
    const contents = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, std.Io.Limit.limited(max_size)) catch |err| {
        const msg = alloc.print("Failed to read '{s}': {}", .{ path, err }) catch return error.OutOfMemory;
        return registry.ToolResult{ .output = msg, .is_error = true };
    };
    defer alloc.free(contents);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const pw = &aw.writer;
    // True line count: newlines + 1, minus the trailing-newline artifact
    // ("a\nb\n" is 2 lines, "a\nb" is 2 too, "" is 0).
    const total_lines: usize = if (contents.len == 0)
        0
    else
        std.mem.count(u8, contents, "\n") + @intFromBool(contents[contents.len - 1] != '\n');
    var line_num: usize = 1;
    var shown: usize = 0;
    const limit: usize = opt_limit orelse std.math.maxInt(usize);
    var it = std.mem.splitSequence(u8, contents, "\n");
    while (it.next()) |line| : (line_num += 1) {
        // line_num > total: the split artifact after a trailing newline.
        if (line_num > total_lines) break;
        if (line_num < start_line) continue;
        if (shown >= limit) break;
        pw.print("{d:6}\t{s}\n", .{ line_num, line }) catch break;
        shown += 1;
    }
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
