/// Ripgrep CLI wrapper — content search via rg, falling back to grep.
/// The backend choice is resolved ONCE per process (PATH scan, absolute
/// path cached in static buffers): the old flow spawned rg and fell back to
/// grep on failure for every single search — two process launches whenever
/// rg was absent, and a fresh PATH resolution even when present. Searches
/// now also run with a hard timeout and a 1 MiB capture cap, and parsing
/// stops at max_matches instead of materializing every hit.
const std = @import("std");
const find_executable = @import("find_executable.zig");

pub const GrepMatch = struct {
    file_path: []const u8,
    line_number: u32,
    line_content: []const u8,
};

pub const GrepResult = struct {
    matches: []GrepMatch,
    total_matches: usize,
    files_with_matches: usize,
    /// True when parsing stopped early at max_matches (the search child may
    /// have produced more hits than kept).
    truncated: bool = false,
};

/// Hard wall-clock bound for one search invocation.
const search_timeout_s: i64 = 30;
/// Child stdout capture ceiling — bounds memory before parsing caps it.
const capture_limit: usize = 1024 * 1024;
/// Parsing stops here even if the capture is not yet exhausted.
pub const max_matches: usize = 500;

/// Which backend a search will use, resolved once. Static buffers — no
/// allocation, no teardown.
const Backend = enum { rg, grep, none };

var backend_once = std.Io.Mutex.init;
var resolved_backend: ?Backend = null;
var rg_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
var rg_path_len: usize = 0;
var grep_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
var grep_path_len: usize = 0;

/// Resolve the backend once (process lifetime). Needs an allocator only
/// transiently for findExecutable; paths land in static buffers.
fn resolveBackend(allocator: std.mem.Allocator, io: std.Io) Backend {
    backend_once.lockUncancelable(io);
    defer backend_once.unlock(io);
    if (resolved_backend) |b| return b;

    var b: Backend = .none;
    if (find_executable.findExecutable(allocator, "rg") catch null) |p| {
        defer allocator.free(p);
        if (p.len <= rg_path_buf.len) {
            @memcpy(rg_path_buf[0..p.len], p);
            rg_path_len = p.len;
            b = .rg;
        }
    }
    if (b == .none) {
        if (find_executable.findExecutable(allocator, "grep") catch null) |p| {
            defer allocator.free(p);
            if (p.len <= grep_path_buf.len) {
                @memcpy(grep_path_buf[0..p.len], p);
                grep_path_len = p.len;
                b = .grep;
            }
        }
    }
    resolved_backend = b;
    return b;
}

/// Free a GrepResult and every string it owns.
pub fn freeResult(allocator: std.mem.Allocator, result: GrepResult) void {
    for (result.matches) |m| {
        allocator.free(m.file_path);
        allocator.free(m.line_content);
    }
    allocator.free(result.matches);
}

/// Search for a pattern in files using ripgrep (rg), falling back to grep
/// when rg is not on PATH. Caller owns all returned data.
pub fn search(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
    io: std.Io,
) !GrepResult {
    return switch (resolveBackend(allocator, io)) {
        .rg => searchWith(rg_path_buf[0..rg_path_len], &.{
            "--no-heading",
            "--line-number",
            "--color=never",
            // Per-file match cap: bounds pathological single files so the
            // child's own output stays sane alongside the capture limit.
            "-m",
            "1000",
            pattern,
            path,
        }, allocator, io),
        .grep => searchWith(grep_path_buf[0..grep_path_len], &.{
            "-rn",
            "--color=never",
            "-E",
            "-m",
            "1000",
            pattern,
            path,
        }, allocator, io),
        .none => error.NoSearchBackend,
    };
}

fn searchWith(
    exe: []const u8,
    extra_argv: []const []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) !GrepResult {
    var argv = try allocator.alloc([]const u8, 1 + extra_argv.len);
    defer allocator.free(argv);
    argv[0] = exe;
    @memcpy(argv[1..], extra_argv);

    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromSeconds(search_timeout_s),
            .clock = .awake,
        } },
        .stdout_limit = std.Io.Limit.limited(capture_limit),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    }) catch |err| switch (err) {
        error.Timeout => return error.SearchTimedOut,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // exit 1 = "no matches" (not an error); exit 2 = real failure.
    if (result.term != .exited or result.term.exited > 1) {
        return .{ .matches = &.{}, .total_matches = 0, .files_with_matches = 0 };
    }

    return parseGrepOutput(allocator, result.stdout);
}

fn parseGrepOutput(allocator: std.mem.Allocator, output: []const u8) !GrepResult {
    var matches = std.ArrayList(GrepMatch).empty;
    defer matches.deinit(allocator);

    var files_seen = std.ArrayList([]const u8).empty;
    defer files_seen.deinit(allocator);

    var truncated = false;
    var lines = std.mem.splitSequence(u8, output, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse format: "path:line_num:content"
        const colon1 = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const colon2 = std.mem.indexOfScalarPos(u8, line, colon1 + 1, ':') orelse continue;

        const file_path = try allocator.dupe(u8, line[0..colon1]);
        errdefer allocator.free(file_path);
        const line_num_str = line[colon1 + 1 .. colon2];
        const line_num = std.fmt.parseInt(u32, line_num_str, 10) catch {
            allocator.free(file_path);
            continue;
        };
        const content = try allocator.dupe(u8, line[colon2 + 1 ..]);
        errdefer allocator.free(content);

        try matches.append(allocator, .{
            .file_path = file_path,
            .line_number = line_num,
            .line_content = content,
        });

        // Track unique files
        var seen = false;
        for (files_seen.items) |f| {
            if (std.mem.eql(u8, f, file_path)) {
                seen = true;
                break;
            }
        }
        if (!seen) try files_seen.append(allocator, file_path);

        if (matches.items.len >= max_matches) {
            truncated = true;
            break;
        }
    }

    return .{
        .matches = try matches.toOwnedSlice(allocator),
        .total_matches = matches.items.len,
        .files_with_matches = files_seen.items.len,
        .truncated = truncated,
    };
}

test "parseGrepOutput caps at max_matches and marks truncated" {
    const alloc = std.testing.allocator;
    // max_matches + 5 lines of input.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    var i: usize = 0;
    while (i < max_matches + 5) : (i += 1) {
        try input.print(alloc, "src/f{d}.zig:{d}:hit\n", .{ i, i + 1 });
    }
    const result = try parseGrepOutput(alloc, input.items);
    defer freeResult(alloc, result);
    try std.testing.expectEqual(max_matches, result.matches.len);
    try std.testing.expect(result.truncated);
}

test "parseGrepOutput exit-1-style empty output" {
    const alloc = std.testing.allocator;
    const result = try parseGrepOutput(alloc, "");
    defer freeResult(alloc, result);
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    try std.testing.expect(!result.truncated);
}
