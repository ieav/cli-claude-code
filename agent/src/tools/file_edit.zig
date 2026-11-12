/// FileEdit tool — find and replace strings in a file.
const std = @import("std");
const registry = @import("registry.zig");
const treesitter = @import("../util/treesitter.zig");

/// 1-based line number containing byte offset `pos`.
fn lineOfOffset(contents: []const u8, pos: usize) usize {
    var line: usize = 1;
    for (contents[0..@min(pos, contents.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

/// Self-healing failure feedback: on "not found", show the closest
/// anchor (the first line of old_string searched as a plain substring)
/// with a few context lines, so the model can correct its old_string in
/// ONE retry instead of re-reading the whole file (each failed edit used
/// to cost a full FileRead round trip).
fn notFoundReport(alloc: std.mem.Allocator, path: []const u8, contents: []const u8, old_string: []const u8) !registry.ToolResult {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const pw = &aw.writer;
    try pw.print("old_string not found in {s} (it must match byte-for-byte, including indentation and blank lines).", .{path});
    // Anchor = the first non-empty line of old_string: usually where the
    // whitespace drifted.
    var anchor: []const u8 = "";
    var it = std.mem.splitScalar(u8, old_string, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len > 0) {
            anchor = t;
            break;
        }
    }
    if (anchor.len > 0) {
        if (std.mem.indexOf(u8, contents, anchor)) |p| {
            const line = lineOfOffset(contents, p);
            try pw.print(" Closest match for its first line is at line {d} — the surrounding file content is:\n", .{line});
            // Context: 2 lines before .. 4 after the anchor line.
            const start_line: usize = if (line > 2) line - 2 else 1;
            var li: usize = 1;
            var lit = std.mem.splitScalar(u8, contents, '\n');
            while (lit.next()) |ln| : (li += 1) {
                if (li >= start_line and li <= line + 4) {
                    try pw.print("{d:6}\t{s}\n", .{ li, ln });
                }
                if (li > line + 4) break;
            }
            try pw.print("(copy old_string verbatim from these lines, adding context lines until it is unique)", .{});
        } else {
            try pw.print(" Even its first non-empty line was not found — the text may have changed; re-read the file.", .{});
        }
    }
    var out = aw.toArrayList();
    return registry.ToolResult{ .output = try out.toOwnedSlice(alloc), .is_error = true };
}

/// On "not unique", list every occurrence's line number so the model can
/// extend its context lines to disambiguate (or pick replaceAll) without
/// another exploratory read.
fn notUniqueReport(alloc: std.mem.Allocator, contents: []const u8, old_string: []const u8) !registry.ToolResult {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const pw = &aw.writer;
    try pw.print("old_string is not unique — found at lines ", .{});
    var pos: usize = 0;
    var n: usize = 0;
    while (std.mem.indexOfPos(u8, contents, pos, old_string)) |p| {
        if (n >= 10) {
            try pw.print("…", .{});
            break;
        }
        if (n > 0) try pw.print(", ", .{});
        try pw.print("{d}", .{lineOfOffset(contents, p)});
        pos = p + old_string.len;
        n += 1;
    }
    try pw.print(". Add surrounding context lines until it is unique, or set replaceAll=true.", .{});
    var out = aw.toArrayList();
    return registry.ToolResult{ .output = try out.toOwnedSlice(alloc), .is_error = true };
}

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const path = registry.getStringField(input, "path") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: path") catch "", .is_error = true };
    const old_string = registry.getStringField(input, "old_string") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: old_string") catch "", .is_error = true };
    const new_string = registry.getStringField(input, "new_string") orelse
        return registry.ToolResult{ .output = alloc.dupe(u8, "Missing required field: new_string") catch "", .is_error = true };
    const replace_all_flag = if (registry.getBool(input, "replaceAll")) |v| v else false;

    if (old_string.len == 0) {
        return registry.ToolResult{ .output = alloc.dupe(u8, "old_string cannot be empty") catch "", .is_error = true };
    }

    // Read file
    const contents = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
        return registry.ToolResult{
            .output = try alloc.print("Cannot read file: {}", .{err}),
            .is_error = true,
        };
    };
    defer alloc.free(contents);

    // Find old_string
    const first_pos = std.mem.indexOf(u8, contents, old_string) orelse
        return notFoundReport(alloc, path, contents, old_string);

    // Verify uniqueness unless replaceAll
    if (!replace_all_flag) {
        const second_pos = std.mem.indexOfPos(u8, contents, first_pos + old_string.len, old_string);
        if (second_pos != null) {
            return notUniqueReport(alloc, contents, old_string);
        }
    }

    // Build new content
    var new_contents = std.ArrayList(u8).empty;
    defer new_contents.deinit(alloc);

    if (replace_all_flag) {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, contents, start, old_string)) |pos| {
            try new_contents.appendSlice(alloc, contents[start..pos]);
            try new_contents.appendSlice(alloc, new_string);
            start = pos + old_string.len;
        }
        try new_contents.appendSlice(alloc, contents[start..]);
    } else {
        try new_contents.appendSlice(alloc, contents[0..first_pos]);
        try new_contents.appendSlice(alloc, new_string);
        try new_contents.appendSlice(alloc, contents[first_pos + old_string.len ..]);
    }

    // Write back
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = new_contents.items,
    }) catch |err| {
        return registry.ToolResult{
            .output = try alloc.print("Cannot write file: {}", .{err}),
            .is_error = true,
        };
    };

    const count = if (replace_all_flag)
        std.mem.count(u8, contents, old_string)
    else
        @as(usize, 1);

    // ③ 里程碑 1：落盘后语法校验（内存里的新内容，不回读磁盘）。有错附
    // 警告行让模型当场自纠；未知扩展名/超限 → null 零成本跳过。
    // 所有权：output 必须 alloc-owned（history freeContentBlocks 无差别
    // free）——base 拼接后同样要释放，静态串一律不允许。
    // Line number in the success line: cheap positional grounding for
    // the model's next edit in the same file.
    const base = try alloc.print("Replaced {d} occurrence(s) at line {d} in {s}", .{ count, lineOfOffset(contents, first_pos), path });
    if (treesitter.appendValidationWarning(alloc, path, new_contents.items)) |warn| {
        defer alloc.free(warn);
        defer alloc.free(base); // concat 在 return 表达式先求值，defer 后跑——安全
        return registry.ToolResult{
            .output = try std.mem.concat(alloc, u8, &.{ base, warn }),
        };
    }
    return registry.ToolResult{ .output = base };
}

fn fileEditIsConcurrencySafe(_: std.json.Value) bool {
    return false;
}

fn fileEditValidateInput(input: std.json.Value) registry.ValidationResult {
    const path = registry.getStringField(input, "path") orelse
        return .{ .invalid = .{ .message = "path is required" } };
    if (path.len == 0) return .{ .invalid = .{ .message = "path cannot be empty" } };

    const old_string = registry.getStringField(input, "old_string") orelse
        return .{ .invalid = .{ .message = "old_string is required" } };
    if (old_string.len == 0) return .{ .invalid = .{ .message = "old_string cannot be empty" } };

    _ = registry.getStringField(input, "new_string") orelse
        return .{ .invalid = .{ .message = "new_string is required" } };

    return .valid;
}

test "lineOfOffset counts 1-based lines" {
    try std.testing.expectEqual(@as(usize, 1), lineOfOffset("abc", 0));
    try std.testing.expectEqual(@as(usize, 2), lineOfOffset("a\nb\n", 2));
    try std.testing.expectEqual(@as(usize, 3), lineOfOffset("a\nbb\nccc", 5));
}

test "not-found report carries the closest match and context" {
    const alloc = std.testing.allocator;
    const contents = "fn one() {\n    alpha();\n}\nfn two() {\n    beta();\n}\n";
    // old_string with drifted indentation on its first line.
    const old_string = "  alpha();\n}";
    const r = try notFoundReport(alloc, "t.zig", contents, old_string);
    defer alloc.free(r.output);
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "not found in t.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "line 2") != null); // closest anchor line
    try std.testing.expect(std.mem.indexOf(u8, r.output, "alpha();") != null); // context shown
    // An anchor that appears nowhere names the "re-read" path instead.
    const r2 = try notFoundReport(alloc, "t.zig", contents, "zzz\nqqq");
    defer alloc.free(r2.output);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "re-read the file") != null);
}

test "not-unique report lists occurrence lines" {
    const alloc = std.testing.allocator;
    const contents = "a\nfoo\nb\nfoo\nc\nfoo\n";
    const r = try notUniqueReport(alloc, contents, "foo");
    defer alloc.free(r.output);
    try std.testing.expect(r.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "lines 2, 4, 6") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "replaceAll") != null);
}
