/// Ripgrep CLI wrapper — invoke ripgrep for fast content search.
const std = @import("std");
const subprocess = @import("subprocess.zig");

pub const GrepMatch = struct {
    file_path: []const u8,
    line_number: u32,
    line_content: []const u8,
};

pub const GrepResult = struct {
    matches: []GrepMatch,
    total_matches: usize,
    files_with_matches: usize,
};

/// Search for a pattern in files using ripgrep (rg).
/// Falls back to grep if rg is not available.
/// Caller owns all returned data.
pub fn search(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
    io: std.Io,
) !GrepResult {
    // Try ripgrep first
    if (searchRg(allocator, pattern, path, io)) |result| {
        return result;
    } else |_| {
        // Fall back to grep
        return searchGrep(allocator, pattern, path, io);
    }
}

fn searchRg(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
    io: std.Io,
) !GrepResult {
    const result = try subprocess.exec(allocator, &.{
        "rg",
        "--no-heading",
        "--line-number",
        "--color=never",
        pattern,
        path,
    }, io);

    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return .{ .matches = &.{}, .total_matches = 0, .files_with_matches = 0 };
    }

    return parseGrepOutput(allocator, result.stdout);
}

fn searchGrep(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
    io: std.Io,
) !GrepResult {
    const result = try subprocess.exec(allocator, &.{
        "grep",
        "-rn",
        "--color=never",
        "-E",
        pattern,
        path,
    }, io);

    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return .{ .matches = &.{}, .total_matches = 0, .files_with_matches = 0 };
    }

    return parseGrepOutput(allocator, result.stdout);
}

fn parseGrepOutput(allocator: std.mem.Allocator, output: []const u8) !GrepResult {
    var matches = std.ArrayList(GrepMatch).empty;
    defer matches.deinit(allocator);

    var files_seen = std.ArrayList([]const u8).empty;
    defer files_seen.deinit(allocator);

    var lines = std.mem.splitSequence(u8, output, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse format: "path:line_num:content"
        const colon1 = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const colon2 = std.mem.indexOfScalarPos(u8, line, colon1 + 1, ':') orelse continue;

        const file_path = try allocator.dupe(u8, line[0..colon1]);
        const line_num_str = line[colon1 + 1 .. colon2];
        const line_num = std.fmt.parseInt(u32, line_num_str, 10) catch continue;
        const content = try allocator.dupe(u8, line[colon2 + 1 ..]);

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
    }

    return .{
        .matches = try matches.toOwnedSlice(allocator),
        .total_matches = matches.items.len,
        .files_with_matches = files_seen.items.len,
    };
}
