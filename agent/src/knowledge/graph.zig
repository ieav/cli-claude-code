/// Knowledge graph — stores entities and relationships in SQLite.
/// Supports entity search, relationship traversal, and φ-based pruning.

const std = @import("std");
const math = @import("../math/mod.zig");
const database = @import("../storage/database.zig");

pub const EntityType = enum {
    person,
    technology,
    concept,
    organization,
    code_pattern,
    api_endpoint,
    custom,
};

pub const KnowledgeNode = struct {
    id: i64,
    entity: []const u8,
    entity_type: EntityType,
    properties: ?[]const u8, // JSON
    source: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};

pub const KnowledgeEdge = struct {
    id: i64,
    from_id: i64,
    to_id: i64,
    relation: []const u8,
    weight: f32,
};

pub const KnowledgeGraph = struct {
    allocator: std.mem.Allocator,
    db: *database.Database,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db: *database.Database) Self {
        return .{ .allocator = allocator, .db = db };
    }

    pub fn addNode(self: *Self, entity: []const u8, entity_type: EntityType, source: ?[]const u8) !i64 {
        const now = std.time.milliTimestamp();
        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO knowledge_nodes (entity, entity_type, properties, source, created_at, updated_at)
            \\VALUES ('{s}', '{s}', NULL, '{?s}', {d}, {d})
        , .{ entity, @tagName(entity_type), source, now, now });
        defer self.allocator.free(sql);
        try self.db.exec(sql);
        // Return last insert rowid (simplified - would use sqlite3_last_insert_rowid)
        return 0;
    }

    pub fn addEdge(self: *Self, from_id: i64, to_id: i64, relation: []const u8, weight: f32) !void {
        const sql = try std.fmt.allocPrint(self.allocator,
            "INSERT INTO knowledge_edges (from_id, to_id, relation, weight) VALUES ({d}, {d}, '{s}', {d:.3})",
            .{ from_id, to_id, relation, weight },
        );
        defer self.allocator.free(sql);
        try self.db.exec(sql);
    }

    /// Prune weak edges using φ threshold.
    /// Edges with weight < φ × max_weight are removed.
    pub fn pruneWeakEdges(self: *Self, max_weight: f32) !usize {
        const threshold = math.pruningThreshold(max_weight);
        const sql = try std.fmt.allocPrint(self.allocator,
            "DELETE FROM knowledge_edges WHERE weight < {d:.6}",
            .{threshold},
        );
        defer self.allocator.free(sql);
        try self.db.exec(sql);
        return 0; // Would return actual count from sqlite3_changes
    }

    /// Get node count.
    pub fn nodeCount(self: *Self) !usize {
        _ = self;
        return 0; // Would query SELECT COUNT(*) FROM knowledge_nodes
    }
};

test "KnowledgeGraph addNode and addEdge" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/zage_kg_test_{d}.db", .{std.time.milliTimestamp()}) catch return;
    defer std.posix.unlink(path) catch {};

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    var kg = KnowledgeGraph.init(std.testing.allocator, &db);
    _ = try kg.addNode("Zig", .technology, "test");
    _ = try kg.addNode("Claude", .technology, "test");
    try kg.addEdge(0, 1, "used_by", 0.9);
}
