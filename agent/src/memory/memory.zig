/// Memory system coordinator — dispatches across working/episodic/semantic tiers.
const std = @import("std");
const time_mod = @import("../util/time.zig");
const fs_ops = @import("../util/fs_ops.zig");
const types = @import("types.zig");
const working = @import("working.zig");
const episodic = @import("episodic.zig");
const database = @import("../storage/database.zig");
const vec_dedup = @import("vec_dedup.zig");

pub const MemorySystem = struct {
    allocator: std.mem.Allocator,
    working_mem: working.WorkingMemory,
    episodic_mem: episodic.EpisodicStore,
    /// 语义去重的向量索引挂点（episodic_mem 持库指针，这里复用）。
    db: *database.Database,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db: *database.Database) Self {
        return .{
            .allocator = allocator,
            .working_mem = working.WorkingMemory.init(allocator, 50),
            .episodic_mem = episodic.EpisodicStore.init(allocator, db),
            .db = db,
        };
    }

    pub fn deinit(self: *Self) void {
        self.working_mem.deinit();
        // Finalize the episodic store's cached statements so the Database
        // can close cleanly (an open statement makes sqlite3_close BUSY).
        self.episodic_mem.deinit();
    }

    /// Store a memory entry across tiers.
    /// Working memory is stored first; if the episodic (SQLite) write fails
    /// the error is logged AND returned so callers can skip their
    /// success-counting (the old swallow-and-warn behavior produced
    /// inflated "saved N" counts when the table was missing).
    pub fn store(self: *Self, entry: types.MemoryEntry) !void {
        // Always store in working memory (fast access)
        try self.working_mem.store(entry);

        // Also persist to episodic storage
        self.episodic_mem.store(entry) catch |err| {
            std.debug.print("Warning: episodic store failed: {}\n", .{err});
            return err;
        };
        // ② 语义索引（best-effort：vec 未就绪时内部 no-op）。
        vec_dedup.indexMemory(self.db, entry.id, entry.content);
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
    const path = std.fmt.bufPrint(&tmp, "/tmp/zage_mem_test_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

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
        .created_at = time_mod.nowMillis(),
        .updated_at = time_mod.nowMillis(),
    });

    try std.testing.expectEqual(@as(usize, 1), mem.workingCount());
}
