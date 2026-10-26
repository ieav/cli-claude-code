/// Knowledge graph — stores entities and relationships in SQLite.
/// Supports entity search, relationship traversal, and φ-based pruning.
const std = @import("std");
const time_mod = @import("../util/time.zig");
const fs_ops = @import("../util/fs_ops.zig");
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
        const now = time_mod.nowMillis();
        var stmt = try database.Statement.prepare(
            self.allocator,
            self.db,
            "INSERT INTO knowledge_nodes (entity, entity_type, properties, source, created_at, updated_at) " ++
                "VALUES (?1, ?2, NULL, ?3, ?4, ?5)",
        );
        defer stmt.finalize();
        stmt.bindText(1, entity);
        stmt.bindText(2, @tagName(entity_type));
        if (source) |s| stmt.bindText(3, s);
        stmt.bindInt64(4, now);
        stmt.bindInt64(5, now);
        if (try stmt.step()) return error.UnexpectedRow;
        return self.db.lastInsertRowId();
    }

    pub fn addEdge(self: *Self, from_id: i64, to_id: i64, relation: []const u8, weight: f32) !void {
        var stmt = try database.Statement.prepare(
            self.allocator,
            self.db,
            "INSERT INTO knowledge_edges (from_id, to_id, relation, weight) VALUES (?1, ?2, ?3, ?4)",
        );
        defer stmt.finalize();
        stmt.bindInt64(1, from_id);
        stmt.bindInt64(2, to_id);
        stmt.bindText(3, relation);
        stmt.bindFloat(4, weight);
        if (try stmt.step()) return error.UnexpectedRow;
    }

    /// Prune weak edges using φ threshold.
    /// Edges with weight < φ × max_weight are removed.
    pub fn pruneWeakEdges(self: *Self, max_weight: f32) !usize {
        const threshold = math.pruningThreshold(max_weight);
        var stmt = try database.Statement.prepare(
            self.allocator,
            self.db,
            "DELETE FROM knowledge_edges WHERE weight < ?1",
        );
        defer stmt.finalize();
        stmt.bindFloat(1, threshold);
        _ = try stmt.step();
        return @intCast(self.db.changes());
    }

    /// Get node count.
    pub fn nodeCount(self: *Self) !usize {
        var stmt = try database.Statement.prepare(
            self.allocator,
            self.db,
            "SELECT COUNT(*) FROM knowledge_nodes",
        );
        defer stmt.finalize();
        if (!try stmt.step()) return error.NoRows;
        return @intCast(stmt.columnInt64(0));
    }

    /// A lightweight node row for listings (avoids owning properties JSON).
    pub const NodeRow = struct {
        id: i64,
        entity: []u8,
        entity_type: []u8,
        source: ?[]u8,
        created_at: i64,
    };

    /// Most recently created nodes. Caller owns the slice and every string;
    /// release with freeNodeRows.
    pub fn recentNodes(self: *Self, limit: usize) ![]NodeRow {
        var stmt = try database.Statement.prepare(
            self.allocator,
            self.db,
            "SELECT id, entity, entity_type, source, created_at " ++
                "FROM knowledge_nodes ORDER BY id DESC LIMIT ?1",
        );
        defer stmt.finalize();
        stmt.bindInt64(1, @intCast(limit));

        var rows: std.ArrayList(NodeRow) = .empty;
        errdefer {
            for (rows.items) |r| self.freeNodeRow(r);
            rows.deinit(self.allocator);
        }
        while (try stmt.step()) {
            try rows.append(self.allocator, .{
                .id = stmt.columnInt64(0),
                .entity = try self.allocator.dupe(u8, stmt.columnText(1)),
                .entity_type = try self.allocator.dupe(u8, stmt.columnText(2)),
                .source = if (stmt.columnText(3).len > 0) try self.allocator.dupe(u8, stmt.columnText(3)) else null,
                .created_at = stmt.columnInt64(4),
            });
        }
        return rows.toOwnedSlice(self.allocator);
    }

    fn freeNodeRow(self: *Self, r: NodeRow) void {
        self.allocator.free(r.entity);
        self.allocator.free(r.entity_type);
        if (r.source) |s| self.allocator.free(s);
    }

    pub fn freeNodeRows(self: *Self, rows: []NodeRow) void {
        for (rows) |r| self.freeNodeRow(r);
        self.allocator.free(rows);
    }
};

test "KnowledgeGraph addNode and addEdge" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/zage_kg_test_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    var kg = KnowledgeGraph.init(std.testing.allocator, &db);
    // Node ids are SQLite AUTOINCREMENT (1-based), not array indexes.
    const zig_id = try kg.addNode("Zig", .technology, "test");
    const claude_id = try kg.addNode("Claude", .technology, "test");
    try kg.addEdge(zig_id, claude_id, "used_by", 0.9);

    // Real counts from the parameterized implementations.
    try std.testing.expectEqual(@as(usize, 2), try kg.nodeCount());
    // Edge 0.9 vs threshold phi*1.0=0.618: kept. Add a weak one: pruned.
    const claude_id2 = try kg.addNode("Rust", .technology, null);
    try kg.addEdge(claude_id2, zig_id, "used_by", 0.1);
    const pruned = try kg.pruneWeakEdges(1.0);
    try std.testing.expectEqual(@as(usize, 1), pruned);
    try std.testing.expectEqual(@as(usize, 3), try kg.nodeCount());
}
