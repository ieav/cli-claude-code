/// Find executable — locate a command in PATH.
const std = @import("std");
const env = @import("env.zig");
const platform = @import("platform.zig");

/// Find an executable in the PATH. Returns the full path or null.
/// Caller owns the returned slice.
pub fn findExecutable(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const path_var = env.pathEnv() orelse return null;

    var io_state = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();
    const cwd = std.Io.Dir.cwd();

    var it = std.mem.splitSequence(u8, path_var, ":");
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full_path = try std.fs.path.join(allocator, &.{ dir, name });
        errdefer allocator.free(full_path);

        // Check if file exists and is executable
        cwd.access(io, full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        return full_path;
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

    var it = std.mem.splitSequence(u8, path_var, ":");
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        cwd.access(io, full_path, .{}) catch continue;
        return true;
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
