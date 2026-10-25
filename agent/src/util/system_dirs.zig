/// System directory paths — XDG-compliant paths for config, data, cache.
const std = @import("std");
const env = @import("env.zig");

/// Get the config directory (~/.config/ziv or $XDG_CONFIG_HOME/ziv).
/// Caller owns the returned slice.
pub fn configDir(allocator: std.mem.Allocator) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "ziv" });
    }
    const home = env.homeDir() orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "ziv" });
}

/// Get the data directory (~/.local/share/ziv or $XDG_DATA_HOME/ziv).
/// Caller owns the returned slice.
pub fn dataDir(allocator: std.mem.Allocator) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "ziv" });
    }
    const home = env.homeDir() orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "ziv" });
}

/// Get the cache directory (~/.cache/ziv or $XDG_CACHE_HOME/ziv).
/// Caller owns the returned slice.
pub fn cacheDir(allocator: std.mem.Allocator) ![]u8 {
    if (env.get("XDG_CACHE_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "ziv" });
    }
    const home = env.homeDir() orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".cache", "ziv" });
}

/// Get the checkpoints directory (for file history backups).
/// Caller owns the returned slice.
pub fn checkpointsDir(allocator: std.mem.Allocator) ![]u8 {
    const data = try dataDir(allocator);
    defer allocator.free(data);
    return std.fs.path.join(allocator, &.{ data, "checkpoints" });
}

/// Ensure a directory exists (creates parents as needed).
pub fn ensureDir(dir_path: []const u8, io: std.Io) !void {
    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

test "configDir not empty" {
    const alloc = std.testing.allocator;
    const dir = try configDir(alloc);
    defer alloc.free(dir);
    try std.testing.expect(dir.len > 0);
}
