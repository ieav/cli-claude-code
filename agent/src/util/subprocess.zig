/// Subprocess execution — child process spawning with output capture.
const std = @import("std");

pub const ExecResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    timed_out: bool = false,
};

/// Execute a command and capture stdout/stderr.
/// Caller owns all slices in the result.
pub fn exec(allocator: std.mem.Allocator, argv: []const []const u8, io: std.Io) !ExecResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}

/// Execute a command via /bin/sh -c.
/// Caller owns all slices in the result.
pub fn execShell(allocator: std.mem.Allocator, command: []const u8, io: std.Io) !ExecResult {
    return exec(allocator, &.{ "/bin/sh", "-c", command }, io);
}

/// Execute a command, returning only stdout. Silently ignores failures.
pub fn execQuiet(allocator: std.mem.Allocator, argv: []const []const u8, io: std.Io) ?[]const u8 {
    const result = exec(allocator, argv, io) catch return null;
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return null;
    }
    allocator.free(result.stderr);
    return result.stdout;
}

/// Check if a command is available on the system.
/// Uses PATH lookup without spawning a subprocess.
pub fn isAvailable(command: []const u8) bool {
    const env_mod = @import("env.zig");
    const path_var = env_mod.pathEnv() orelse return false;
    var it = std.mem.splitSequence(u8, path_var, ":");
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, command }) catch continue;
        std.fs.cwd().access(full_path, .{}) catch continue;
        return true;
    }
    return false;
}
