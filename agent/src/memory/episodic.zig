/// Episodic memory — SQLite-backed store for past interaction experiences.
const std = @import("std");
const time_mod = @import("../util/time.zig");
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
        const q_name = try database.Database.quoteString(self.allocator, entry.name);
        defer self.allocator.free(q_name);
        const q_desc = try database.Database.quoteString(self.allocator, entry.description);
        defer self.allocator.free(q_desc);
        const q_content = try database.Database.quoteString(self.allocator, entry.content);
        defer self.allocator.free(q_content);

        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO memories (id, type, scope, name, description, content, access_count, created_at, updated_at)
            \\VALUES (X'{s}', '{s}', 'private', {s}, {s}, {s}, 0, {d}, {d})
        , .{
            std.fmt.fmtSliceHexLower(&entry.id),
            @tagName(entry.mem_type),
            q_name,
            q_desc,
            q_content,
            entry.created_at,
            entry.updated_at,
        });
        defer self.allocator.free(sql);
        try self.db.exec(sql);
    }

    pub fn retrieveRecent(self: *Self, limit: usize) ![]types.MemoryEntry {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT id, type, name, description, content, access_count, created_at, updated_at FROM memories ORDER BY updated_at DESC LIMIT {d}",
            .{limit},
        );
        defer self.allocator.free(sql);
        // TODO: prepared statement iteration for full impl
        return &.{};
    }

    pub fn touch(self: *Self, memory_id: [16]u8) void {
        const sql = std.fmt.allocPrint(
            self.allocator,
            "UPDATE memories SET access_count = access_count + 1, updated_at = {d} WHERE id = X'{s}'",
            .{ time_mod.nowMillis(), std.fmt.fmtSliceHexLower(&memory_id) },
        ) catch return;
        defer self.allocator.free(sql);
        self.db.exec(sql) catch {};
    }
};
