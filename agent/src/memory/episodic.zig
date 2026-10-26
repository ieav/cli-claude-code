/// Episodic memory — SQLite-backed store for past interaction experiences.
/// All queries use prepared statements with bound parameters; user data never
/// becomes part of the SQL text.
const std = @import("std");
const time_mod = @import("../util/time.zig");
const fs_ops = @import("../util/fs_ops.zig");
const types = @import("types.zig");
const database = @import("../storage/database.zig");

pub const EpisodicStore = struct {
    allocator: std.mem.Allocator,
    db: *database.Database,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db: *database.Database) Self {
        return .{ .allocator = allocator, .db = db };
    }

    pub fn store(self: *Self, entry: types.MemoryEntry) !void {
        var stmt = try database.Statement.prepare(self.allocator, self.db,
            \\INSERT OR REPLACE INTO memories (id, type, scope, name, description, content, access_count, created_at, updated_at)
            \\VALUES (?1, ?2, 'private', ?3, ?4, ?5, ?6, ?7, ?8)
        );
        defer stmt.finalize();
        stmt.bindBlob(1, &entry.id);
        stmt.bindText(2, @tagName(entry.mem_type));
        stmt.bindText(3, entry.name);
        stmt.bindText(4, entry.description);
        stmt.bindText(5, entry.content);
        stmt.bindInt64(6, entry.access_count);
        stmt.bindInt64(7, entry.created_at);
        stmt.bindInt64(8, entry.updated_at);
        if (try stmt.step()) return error.UnexpectedRow;
    }

    /// Most recently updated memories first. Caller owns the returned slice
    /// and each entry's strings; release with freeEntries().
    pub fn retrieveRecent(self: *Self, limit: usize) ![]types.MemoryEntry {
        var stmt = try database.Statement.prepare(
            self.allocator,
            self.db,
            "SELECT id, type, name, description, content, access_count, created_at, updated_at " ++
                "FROM memories ORDER BY updated_at DESC LIMIT ?1",
        );
        defer stmt.finalize();
        stmt.bindInt64(1, @intCast(limit));

        var list: std.ArrayList(types.MemoryEntry) = .empty;
        errdefer {
            for (list.items) |e| self.freeEntry(e);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) {
            const id_blob = stmt.columnBlob(0);
            var id: [16]u8 = @splat(0);
            if (id_blob.len == 16) @memcpy(&id, id_blob);
            const mem_type = std.meta.stringToEnum(types.MemoryType, stmt.columnText(1)) orelse .reference;
            try list.append(self.allocator, .{
                .id = id,
                .mem_type = mem_type,
                .name = try self.allocator.dupe(u8, stmt.columnText(2)),
                .description = try self.allocator.dupe(u8, stmt.columnText(3)),
                .content = try self.allocator.dupe(u8, stmt.columnText(4)),
                .access_count = @intCast(@max(0, stmt.columnInt64(5))),
                .created_at = stmt.columnInt64(6),
                .updated_at = stmt.columnInt64(7),
            });
        }
        return list.toOwnedSlice(self.allocator);
    }

    /// Bump access_count and updated_at for one memory. Best effort: errors
    /// are swallowed, matching the previous behavior.
    pub fn touch(self: *Self, memory_id: [16]u8) void {
        var stmt = database.Statement.prepare(
            self.allocator,
            self.db,
            "UPDATE memories SET access_count = access_count + 1, updated_at = ?1 WHERE id = ?2",
        ) catch return;
        defer stmt.finalize();
        stmt.bindInt64(1, time_mod.nowMillis());
        stmt.bindBlob(2, &memory_id);
        _ = stmt.step() catch {};
    }

    fn freeEntry(self: *Self, entry: types.MemoryEntry) void {
        self.allocator.free(entry.name);
        self.allocator.free(entry.description);
        self.allocator.free(entry.content);
    }

    pub fn freeEntries(self: *Self, entries: []types.MemoryEntry) void {
        for (entries) |e| self.freeEntry(e);
        self.allocator.free(entries);
    }
};

test "EpisodicStore parameterized round-trip with injection payload" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/ziv_episodic_param_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    var store = EpisodicStore.init(std.testing.allocator, &db);

    const payload = "'; DROP TABLE memories;--";
    var id: [16]u8 = undefined;
    for (&id, 0..) |*byte, i| byte.* = @intCast(i + 200);
    try store.store(.{
        .id = id,
        .mem_type = .project,
        .name = payload,
        .description = payload,
        .content = payload,
        .access_count = 0,
        .created_at = time_mod.nowMillis(),
        .updated_at = time_mod.nowMillis(),
    });

    const entries = try store.retrieveRecent(10);
    defer store.freeEntries(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(payload, entries[0].name);
    try std.testing.expectEqualStrings(payload, entries[0].content);
    try std.testing.expectEqual(types.MemoryType.project, entries[0].mem_type);
    try std.testing.expectEqual(id, entries[0].id);

    // The injection payload must not have dropped the table.
    try std.testing.expect(try db.checkIntegrity());

    // touch() must affect exactly the stored row.
    store.touch(id);
    const after = try store.retrieveRecent(10);
    defer store.freeEntries(after);
    try std.testing.expectEqual(@as(u32, 1), after[0].access_count);
}
