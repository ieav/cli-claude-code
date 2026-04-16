/// Episodic memory — SQLite-backed store for past interaction experiences.

const std = @import("std");
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
        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO memories (id, type, scope, name, description, content, access_count, created_at, updated_at)
            \\VALUES (?, '{s}', 'private', '{s}', '{s}', '{s}', 0, {d}, {d})
        , .{
            @tagName(entry.mem_type),
            entry.name,
            entry.description,
            entry.content,
            entry.created_at,
            entry.updated_at,
        });
        defer self.allocator.free(sql);
        try self.db.exec(sql);
    }

    pub fn retrieveRecent(self: *Self, limit: usize) ![]types.MemoryEntry {
        const sql = try std.fmt.allocPrint(self.allocator,
            "SELECT id, type, name, description, content, access_count, created_at, updated_at FROM memories ORDER BY updated_at DESC LIMIT {d}",
            .{limit},
        );
        defer self.allocator.free(sql);
        // TODO: prepared statement iteration for full impl
        return &.{};
    }

    pub fn touch(self: *Self, memory_id: [16]u8) void {
        const sql = std.fmt.comptimePrint(
            "UPDATE memories SET access_count = access_count + 1, updated_at = {d} WHERE id = ?",
            .{std.time.milliTimestamp()},
        );
        self.db.exec(sql) catch {};
        _ = memory_id;
    }
};
