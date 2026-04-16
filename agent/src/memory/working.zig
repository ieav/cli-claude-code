/// Working memory — in-memory bounded LRU cache for current session context.

const std = @import("std");
const types = @import("types.zig");

pub const WorkingMemory = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(types.MemoryEntry),
    max_entries: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) Self {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(types.MemoryEntry).init(allocator),
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.description);
            self.allocator.free(entry.content);
        }
        self.entries.deinit();
    }

    pub fn store(self: *Self, entry: types.MemoryEntry) !void {
        // Evict oldest if at capacity
        if (self.entries.items.len >= self.max_entries) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old.name);
            self.allocator.free(old.description);
            self.allocator.free(old.content);
        }
        try self.entries.append(entry);
    }

    pub fn retrieve(self: *Self, query: []const u8, max_results: usize) []const types.MemoryEntry {
        _ = query;
        const n = @min(max_results, self.entries.items.len);
        return self.entries.items[self.entries.items.len - n ..];
    }

    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    pub fn clear(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.description);
            self.allocator.free(entry.content);
        }
        self.entries.clearRetainingCapacity();
    }
};

test "WorkingMemory store and retrieve" {
    var wm = WorkingMemory.init(std.testing.allocator, 3);
    defer wm.deinit();

    try wm.store(.{
        .id = std.mem.zeroes([16]u8),
        .mem_type = .user,
        .name = "test1",
        .description = "desc1",
        .content = "content1",
        .access_count = 0,
        .created_at = 0,
        .updated_at = 0,
    });

    try std.testing.expectEqual(@as(usize, 1), wm.count());
    const results = wm.retrieve("test", 5);
    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "WorkingMemory eviction" {
    var wm = WorkingMemory.init(std.testing.allocator, 2);
    defer wm.deinit();

    for (0..3) |_| {
        try wm.store(.{
            .id = std.mem.zeroes([16]u8),
            .mem_type = .user,
            .name = "test",
            .description = "desc",
            .content = "content",
            .access_count = 0,
            .created_at = 0,
            .updated_at = 0,
        });
    }
    // Should have evicted down to 2
    try std.testing.expectEqual(@as(usize, 2), wm.count());
}
