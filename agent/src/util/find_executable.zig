/// Find executable — locate a command in PATH.
const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");

/// Windows PATH is `;`-separated and executables carry suffixes.
const path_sep: []const u8 = if (builtin.os.tag == .windows) ";" else ":";
const exe_suffixes: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "", ".exe", ".bat", ".cmd" }
else
    &.{""};

/// Find an executable in the PATH. Returns the full path or null.
/// Caller owns the returned slice.
pub fn findExecutable(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const path_var = env.pathEnv() orelse return null;

    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();
    const cwd = std.Io.Dir.cwd();

    var it = std.mem.splitSequence(u8, path_var, path_sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        for (exe_suffixes) |sfx| {
            const joined = try std.fs.path.join(allocator, &.{ dir, name });
            defer allocator.free(joined);
            const full_path = if (sfx.len == 0)
                try allocator.dupe(u8, joined)
            else
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ joined, sfx });
            errdefer allocator.free(full_path);

            cwd.access(io, full_path, .{}) catch {
                allocator.free(full_path);
                continue;
            };
            return full_path;
        }
    }
    return null;
}

/// Check if a command exists in PATH.
pub fn commandExists(name: []const u8) bool {
    const path_var = env.pathEnv() orelse return false;

    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();
    const cwd = std.Io.Dir.cwd();

    var it = std.mem.splitSequence(u8, path_var, path_sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        for (exe_suffixes) |sfx| {
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ dir, name, sfx }) catch continue;
            cwd.access(io, full_path, .{}) catch continue;
            return true;
        }
    }
    return false;
}

test "findExecutable ls" {
    const alloc = std.testing.allocator;
    const result = try findExecutable(alloc, "ls");
    if (result) |path| {
        defer alloc.free(path);
        try std.testing.expect(path.len > 0);
    }
}

test "commandExists ls" {
    try std.testing.expect(commandExists("ls"));
    try std.testing.expect(!commandExists("nonexistent_command_xyz_12345"));
}
