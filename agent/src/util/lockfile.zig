/// Lockfile — simple file-based mutual exclusion.
const std = @import("std");

pub const LockFile = struct {
    path: []const u8,
    allocator: std.mem.Allocator,
    held: bool = false,

    const Self = @This();

    /// Try to acquire a lock. Returns error if already locked.
    pub fn acquire(self: *Self) !void {
        if (self.held) return;

        // Try to create the lock file exclusively
        const file = std.fs.cwd().createFile(self.path, .{
            .exclusive = true,
            .truncate = false,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.AlreadyLocked,
            else => return err,
        };
        defer file.close();

        // Write PID to lock file
        const writer = file.writer();
        writer.print("{d}", .{std.posix.getpid()}) catch {};
        self.held = true;
    }

    /// Release the lock by deleting the lock file.
    pub fn release(self: *Self) void {
        if (!self.held) return;
        std.fs.cwd().deleteFile(self.path) catch {};
        self.held = false;
    }

    pub fn deinit(self: *Self) void {
        self.release();
        self.allocator.free(self.path);
    }
};

/// Create a lock file at the given path. Caller must deinit when done.
pub fn create(allocator: std.mem.Allocator, path: []const u8) !*LockFile {
    const lock = try allocator.create(LockFile);
    lock.* = .{
        .path = try allocator.dupe(u8, path),
        .allocator = allocator,
    };
    return lock;
}

test "LockFile acquire/release" {
    const alloc = std.testing.allocator;
    const path = "/tmp/ziv_test_lock";

    var lock = LockFile{
        .path = path,
        .allocator = alloc,
        .held = false,
    };
    defer lock.release();

    try lock.acquire();
    try std.testing.expect(lock.held);
    lock.release();
    try std.testing.expect(!lock.held);
}
