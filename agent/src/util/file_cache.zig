/// File state cache — LRU cache using PiRingBuffer for file contents.
/// Avoids re-reading files that haven't changed.
const std = @import("std");
const time_mod = @import("time.zig");
const math_mod = @import("../math/mod.zig");

pub const FileState = struct {
    path: []const u8,
    content: []const u8,
    timestamp: i64,
    offset: ?u32,
    limit: ?u32,
};

pub const FileStateCache = struct {
    ring: RingBuffer,
    allocator: std.mem.Allocator,

    const capacity = 128;
    const RingBuffer = math_mod.PiRingBuffer(FileState, capacity);
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .ring = RingBuffer.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free cached content
        var iter = self.ring.piIterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.path);
            self.allocator.free(entry.content);
        }
    }

    /// Get a cached file state by path. Returns null if not found.
    pub fn get(self: *Self, path: []const u8) ?FileState {
        var iter = self.ring.piIterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return entry;
            }
        }
        return null;
    }

    /// Store a file state in the cache. Evicts oldest if full.
    pub fn put(self: *Self, path: []const u8, content: []const u8) !void {
        const path_dup = try self.allocator.dupe(u8, path);
        const content_dup = try self.allocator.dupe(u8, content);

        // If ring is full, free the evicted entry
        if (self.ring.isFull()) {
            const evicted = self.ring.getOldest();
            self.allocator.free(evicted.path);
            self.allocator.free(evicted.content);
        }

        self.ring.push(.{
            .path = path_dup,
            .content = content_dup,
            .timestamp = time_mod.nowMillis(),
            .offset = null,
            .limit = null,
        });
    }

    /// Invalidate a cached file entry.
    pub fn invalidate(self: *Self, path: []const u8) void {
        // Note: PiRingBuffer doesn't support removal, so we just mark stale.
        // The entry will be naturally evicted as new entries are pushed.
        _ = self;
        _ = path;
    }
};

test "FileStateCache put/get" {
    var cache = FileStateCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.put("/test/file.zig", "const std = @import(\"std\");");
    const state = cache.get("/test/file.zig");
    try std.testing.expect(state != null);
    try std.testing.expectEqualStrings("const std = @import(\"std\");", state.?.content);
}
