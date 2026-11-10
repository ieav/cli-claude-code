/// DirTree tool — structural overview of a directory ("给我看结构").
/// Glob answers "which files match a pattern"; this answers "what does
/// this project look like" — the model's first move in an unfamiliar tree
/// used to be several blind Glob rounds stitched into a guess.
///
/// Same traversal discipline as Glob: vendored/build dirs (glob.
/// excluded_dirs) pruned wholesale, directory symlinks not followed,
/// depth bounded (default 3 — an overview, not an inventory), entry count
/// capped with a visible truncation note. Per-level entries are collected
/// and SORTED (directories first, then files, both alphabetical) —
/// iterate order is filesystem-dependent and a stable layout reads better
/// for both the model and the transcript.
const std = @import("std");
const registry = @import("registry.zig");
const glob = @import("glob.zig");

const default_max_depth: u32 = 3;
const default_max_entries: usize = 400;
const hard_entry_cap: usize = 2000;
const path_buf_len = 4096;

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const path = registry.getStringField(input, "path") orelse ".";
    const max_depth: u32 = @intCast(registry.getIntField(input, "maxDepth") orelse default_max_depth);
    const raw_entries: i64 = registry.getIntField(input, "maxEntries") orelse default_max_entries;
    const max_entries: usize = @min(@max(raw_entries, 1), hard_entry_cap);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var state = TreeState{
        .alloc = alloc,
        .io = io,
        .max_depth = max_depth,
        .max_entries = max_entries,
    };

    var root_dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        return registry.ToolResult{
            .output = try alloc.print("Cannot open directory: {s}", .{path}),
            .is_error = true,
        };
    };
    defer root_dir.close(io);
    try out.print(alloc, "{s}/\n", .{path});
    try walk(root_dir, 1, &state, &out, &state.indent_buf);

    if (state.truncated) {
        try out.print(alloc, "… (截断于 {d} 条；可用 maxDepth/maxEntries 调整或分目录查看)\n", .{state.count});
    }
    if (state.read_errors > 0) {
        try out.print(alloc, "… ({d} 个目录读取失败)\n", .{state.read_errors});
    }
    return registry.ToolResult{ .output = try out.toOwnedSlice(alloc) };
}

const TreeState = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    max_depth: u32,
    max_entries: usize,
    count: usize = 0,
    truncated: bool = false,
    read_errors: usize = 0,
    /// Indent text (two spaces per level), rebuilt per descent.
    indent_buf: [256]u8 = undefined,
};

const Entry = struct {
    name: []const u8, // borrowed from the per-level arena
    is_dir: bool,
};

/// Sort order: directories first, then files, both alphabetical.
fn entryLess(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn walk(d: std.Io.Dir, depth: u32, state: *TreeState, out: *std.ArrayList(u8), indent_buf: []u8) !void {
    if (depth > state.max_depth) return;
    // depth 1 = the root's direct children → two spaces (the root line
    // itself is printed by execute()); each deeper level adds two more.
    const indent_len = @min(depth * 2, indent_buf.len);
    @memset(indent_buf[0..indent_len], ' ');

    // Collect this level's entries into a per-call arena (names are
    // borrowed from the iterator; the arena keeps them alive until the
    // level finishes rendering).
    var arena = std.heap.ArenaAllocator.init(state.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(a);

    var it = d.iterate();
    while (true) {
        const ent = it.next(state.io) catch {
            state.read_errors += 1;
            break;
        } orelse break;
        switch (ent.kind) {
            .directory => {
                // Pruned trees vanish wholesale (same list Glob uses).
                if (glob.isExcluded(ent.name)) continue;
                const owned = a.dupe(u8, ent.name) catch continue;
                try entries.append(a, .{ .name = owned, .is_dir = true });
            },
            .file, .sym_link => { // symlinks listed, never followed
                const owned = a.dupe(u8, ent.name) catch continue;
                try entries.append(a, .{ .name = owned, .is_dir = false });
            },
            else => {}, // sockets/fifos/devices: not part of an overview
        }
    }
    std.mem.sort(Entry, entries.items, {}, entryLess);

    for (entries.items) |e| {
        if (state.count >= state.max_entries) {
            state.truncated = true;
            return;
        }
        state.count += 1;
        try out.appendSlice(state.alloc, indent_buf[0..indent_len]);
        try out.appendSlice(state.alloc, e.name);
        if (e.is_dir) try out.appendSlice(state.alloc, "/\n") else try out.append(state.alloc, '\n');
        if (e.is_dir) {
            var child = d.openDir(state.io, e.name, .{ .iterate = true }) catch continue;
            defer child.close(state.io);
            try walk(child, depth + 1, state, out, indent_buf);
            if (state.truncated) return;
        }
    }
}

test "dir tree: prune/depth/cap and stable order" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const ts: u32 = @truncate(@as(u64, @bitCast(@import("../util/time.zig").nowMillis())));
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/ziv_dtree_{d}", .{ts});
    // Layout: src/(llm/mod.zig, zz_last.zig), docs/a.md, README.md;
    // node_modules/x.js must vanish; d4.txt sits beyond maxDepth=2.
    const dirs = [_][]const u8{ "/src/llm", "/docs", "/node_modules/pkg", "/src/deep4" };
    for (dirs) |rel| {
        var pb: [192]u8 = undefined;
        const p = try std.fmt.bufPrint(&pb, "{s}{s}", .{ base, rel });
        std.Io.Dir.cwd().createDirPath(io, p) catch unreachable;
    }
    const files = [_][]const u8{
        "/README.md",           "/node_modules/pkg/x.js", "/src/llm/mod.zig",
        "/src/llm/zz_last.zig", "/src/deep4/d4.txt",     "/docs/a.md",
    };
    for (files) |rel| {
        var pb: [192]u8 = undefined;
        const p = try std.fmt.bufPrint(&pb, "{s}{s}", .{ base, rel });
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "x" }) catch unreachable;
    }
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    // Input DOM via a printed JSON literal (tmp paths contain no quotes).
    var arena2 = std.heap.ArenaAllocator.init(alloc);
    defer arena2.deinit();
    var json_buf: [192]u8 = undefined;
    const json = try std.fmt.bufPrint(&json_buf, "{{\"path\":\"{s}\",\"maxDepth\":2}}", .{base});
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena2.allocator(), json, .{});
    const res = try execute(alloc, input, io);
    defer alloc.free(res.output);
    try std.testing.expect(!res.is_error);

    // Level 1 order: directories alphabetical (docs, src), files after
    // (README.md last). Verified live before pinning.
    const readme = std.mem.indexOf(u8, res.output, "README.md") orelse return error.TestUnexpectedResult;
    const docs = std.mem.indexOf(u8, res.output, "docs/") orelse return error.TestUnexpectedResult;
    const src = std.mem.indexOf(u8, res.output, "src/") orelse return error.TestUnexpectedResult;
    try std.testing.expect(docs < src and src < readme);
    // Within src/: depth-2 dirs visible (deep4/, llm/ — their CONTENT is
    // what maxDepth=2 cuts), alphabetical.
    const deep4 = std.mem.indexOf(u8, res.output, "deep4/") orelse return error.TestUnexpectedResult;
    const llm = std.mem.indexOf(u8, res.output, "llm/") orelse return error.TestUnexpectedResult;
    try std.testing.expect(deep4 < llm);
    // Pruned tree vanishes; depth-3 entries (files under llm/ and deep4/)
    // are cut by maxDepth=2.
    try std.testing.expect(std.mem.indexOf(u8, res.output, "node_modules") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "mod.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "zz_last.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "d4.txt") == null);
}
