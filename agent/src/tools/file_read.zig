/// FileRead tool — reads file contents with line numbers.
/// Repeat reads of an unchanged file are served from the process-wide
/// FileStateCache (validated by mtime+size): no disk IO, no per-line
/// formatting, and one shared allocation per unique read instead of one
/// per line.
const std = @import("std");
const registry = @import("registry.zig");
const file_cache = @import("../util/file_cache.zig");

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const path = getStringField(input, "path") orelse
        return registry.ToolResult{ .output = "Error: 'path' field is required", .is_error = true };

    const max_size: usize = 1024 * 1024;

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
        const msg = alloc.print("Failed to read '{s}': {}", .{ path, err }) catch "read failed";
        return registry.ToolResult{ .output = msg, .is_error = true };
    };

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

fn sleepMs(ms: u32) void {
    var req: std.c.timespec = .{ .sec = 0, .nsec = @as(i64, ms) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&req, null);
}

test "FileRead formats with line numbers and caches repeats" {
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
