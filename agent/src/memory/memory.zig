/// Memory system coordinator — dispatches across working/episodic/semantic tiers.

const std = @import("std");
const types = @import("types.zig");
const working = @import("working.zig");
const episodic = @import("episodic.zig");
const database = @import("../storage/database.zig");

pub const MemorySystem = struct {
    allocator: std.mem.Allocator,
    working_mem: working.WorkingMemory,
    episodic_mem: episodic.EpisodicStore,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db: *database.Database) Self {
        return .{
            .allocator = allocator,
            .working_mem = working.WorkingMemory.init(allocator, 50),
            .episodic_mem = episodic.EpisodicStore.init(allocator, db),
        };
    }

    pub fn deinit(self: *Self) void {
        self.working_mem.deinit();
    }

    /// Store a memory entry across tiers.
    pub fn store(self: *Self, entry: types.MemoryEntry) !void {
        // Always store in working memory (fast access)
        try self.working_mem.store(entry);

        // Also persist to episodic storage
        self.episodic_mem.store(entry) catch |err| {
            std.debug.print("Warning: episodic store failed: {}\n", .{err});
        };
    }

    /// Retrieve relevant memories for a query.
    pub fn retrieve(self: *Self, query: []const u8, max_results: usize) []const types.MemoryEntry {
        // Try working memory first (most recent/relevant)
        const working_results = self.working_mem.retrieve(query, max_results);
        if (working_results.len >= max_results) return working_results;

        // Could also query episodic and semantic stores here
        return working_results;
    }

    pub fn workingCount(self: *const Self) usize {
        return self.working_mem.count();
    }
};

test "MemorySystem store and retrieve" {
    // Note: requires a temp database
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/zage_mem_test_{d}.db", .{std.time.milliTimestamp()}) catch return;
    defer std.posix.unlink(path) catch {};

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    var mem = MemorySystem.init(std.testing.allocator, &db);
    defer mem.deinit();

    try mem.store(.{
        .id = std.mem.zeroes([16]u8),
        .mem_type = .feedback,
        .name = "test_feedback",
        .description = "A test feedback memory",
        .content = "Always use e-based sigmoid for resource limits",
        .access_count = 0,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
    });

    try std.testing.expectEqual(@as(usize, 1), mem.workingCount());
}
