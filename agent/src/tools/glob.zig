/// Glob tool — find files matching a pattern in a directory tree.
/// Walks with its own recursion instead of Dir.walk so it can PRUNE: build/
/// vendor directories (.git, target, node_modules, .zig-cache, …) are never
/// entered (their subtrees are skipped wholesale, not filtered after the
/// fact), directory symlinks are not followed (loop-proof), depth is bounded
/// by maxDepth (default 10), and the result list is capped. Patterns match
/// the path relative to the search root (same semantics as the old walker).
const std = @import("std");
const registry = @import("registry.zig");
const glob_match = @import("../util/glob_match.zig");

/// Directory names pruned during traversal — entering them is pure waste
/// for every realistic glob query.
const excluded_dirs = [_][]const u8{
    ".git",         ".hg",        ".svn",    "target", "build",
    "node_modules", ".zig-cache", "zig-out", "dist",   "out",
    "__pycache__",  ".venv",      ".cache",  ".next",
};

const default_max_depth: u32 = 10;
const max_results: usize = 2000;
const path_buf_len = 4096;

pub fn execute(alloc: std.mem.Allocator, input: std.json.Value, io: std.Io) anyerror!registry.ToolResult {
    const pattern = registry.getStringField(input, "pattern") orelse
        return registry.ToolResult{ .output = "Missing required field: pattern", .is_error = true };
    const path = registry.getStringField(input, "path") orelse ".";
    const max_depth: u32 = @intCast(registry.getIntField(input, "maxDepth") orelse default_max_depth);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var state = WalkState{
        .alloc = alloc,
        .io = io,
        .pattern = pattern,
        .root = path,
        .max_depth = max_depth,
        .rel_buf = undefined,
        .rel_len = 0,
    };
    // One handle per level, opened by entry name from its parent — the
    // accumulated rel path is only for pattern matching and output, never
    // for opening.
    var root_dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        return registry.ToolResult{
            .output = try alloc.print("Cannot open directory: {s}", .{path}),
            .is_error = true,
        };
    };
    defer root_dir.close(io);
    try walkDir(root_dir, 0, &state, &out);

    if (state.count == 0) {
        try out.appendSlice(alloc, "No matches found.\n");
    } else if (state.truncated) {
        try out.appendSlice(alloc, "… (result list truncated at 2000 matches)\n");
    }
    // A directory whose entries could not be read (permissions, I/O error)
    // ends its own walk early — say so instead of silently dropping it.
    if (state.read_errors > 0) {
        try out.print(alloc, "… ({d} directories could not be read)\n", .{state.read_errors});
    }

    return registry.ToolResult{ .output = try out.toOwnedSlice(alloc) };
}

const WalkState = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    pattern: []const u8,
    root: []const u8,
    max_depth: u32,
    count: usize = 0,
    truncated: bool = false,
    read_errors: usize = 0,
    /// Accumulated path relative to the search root (built as we descend,
    /// restored on the way back up — no per-entry allocation).
    rel_buf: [path_buf_len]u8,
    rel_len: usize,

    fn rel(self: *const WalkState) []const u8 {
        return self.rel_buf[0..self.rel_len];
    }
};

fn walkDir(d: std.Io.Dir, depth: u32, state: *WalkState, out: *std.ArrayList(u8)) !void {
    if (depth > state.max_depth) return;

    var it = d.iterate();
    while (true) {
        const entry = it.next(state.io) catch {
            state.read_errors += 1;
            break;
        } orelse break;
        if (state.truncated) return;

        switch (entry.kind) {
            .directory => {
                // Prune vendored/build trees wholesale; skip symlinked dirs
                // (no following → no cycles).
                if (isExcluded(entry.name)) continue;
                var child = d.openDir(state.io, entry.name, .{ .iterate = true }) catch continue;
                defer child.close(state.io);
                const mark = state.rel_len;
                appendRel(state, entry.name) catch continue;
                try walkDir(child, depth + 1, state, out);
                state.rel_len = mark; // backtrack
            },
            .file, .sym_link => {
                const mark = state.rel_len;
                appendRel(state, entry.name) catch continue;
                defer state.rel_len = mark;

                if (!glob_match.matchPath(state.pattern, state.rel())) continue;
                if (state.count >= max_results) {
                    state.truncated = true;
                    return;
                }
                try out.appendSlice(state.alloc, state.root);
                if (state.rel_len > 0) {
                    try out.append(state.alloc, '/');
                    try out.appendSlice(state.alloc, state.rel());
                }
                try out.append(state.alloc, '\n');
                state.count += 1;
            },
            else => {},
        }
    }
}

fn appendRel(state: *WalkState, name: []const u8) !void {
    if (state.rel_len > 0) {
        if (state.rel_len + 1 >= path_buf_len) return error.PathTooLong;
        state.rel_buf[state.rel_len] = '/';
        state.rel_len += 1;
    }
    if (state.rel_len + name.len >= path_buf_len) return error.PathTooLong;
    @memcpy(state.rel_buf[state.rel_len..][0..name.len], name);
    state.rel_len += name.len;
}

fn isExcluded(name: []const u8) bool {
    for (excluded_dirs) |x| {
        if (std.mem.eql(u8, name, x)) return true;
    }
    return false;
}

test "glob prunes excluded dirs and honors maxDepth" {
    const alloc = std.testing.allocator;
    var io_state = std.Io.Threaded.init(alloc, .{});
    defer io_state.deinit();
    const io = io_state.io();

    const root = "/tmp/ziv_glob_test";
    // Layout: keep.txt at root; skip.txt inside node_modules (pruned tree);
    // deep.txt at depth 3 (pruned by maxDepth=2); nested dir match at depth 1.
    std.Io.Dir.cwd().createDirPath(io, root ++ "/node_modules/pkg") catch {};
    std.Io.Dir.cwd().createDirPath(io, root ++ "/a/b/c") catch {};
    std.Io.Dir.cwd().createDirPath(io, root ++ "/src") catch {};
    const files = [_][]const u8{
        root ++ "/keep.txt",
        root ++ "/node_modules/pkg/skip.txt",
        root ++ "/a/b/c/deep.txt",
        root ++ "/src/nested.txt",
    };
    for (files) |f| std.Io.Dir.cwd().writeFile(io, .{ .sub_path = f, .data = "x" }) catch {};
    defer for (files) |f| std.Io.Dir.cwd().deleteFile(io, f) catch {};
    defer {
        // Deepest-first so every rmdir sees an empty dir.
        const dirs = [_][]const u8{
            root ++ "/node_modules/pkg", root ++ "/node_modules",
            root ++ "/a/b/c",            root ++ "/a/b",
            root ++ "/a",                root ++ "/src",
            root,
        };
        for (dirs) |d| std.Io.Dir.cwd().deleteDir(io, d) catch {};
    }

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(alloc);
    try obj.put(alloc, "pattern", .{ .string = "*.txt" });
    try obj.put(alloc, "path", .{ .string = root });
    try obj.put(alloc, "maxDepth", .{ .integer = 2 });

    const result = try execute(alloc, .{ .object = obj }, io);
    defer alloc.free(result.output);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "keep.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "nested.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "skip.txt") == null); // pruned tree
    try std.testing.expect(std.mem.indexOf(u8, result.output, "deep.txt") == null); // depth-capped
}
