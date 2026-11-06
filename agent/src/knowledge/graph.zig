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
    // Prepared-once statements: extraction bursts addNode/addEdge/findNodeId
    // ~30 statements in one pass; pruneWeakEdges stays ad-hoc (rare).
    stmt_find_node: database.CachedStatement = .{ .sql =
        "SELECT id FROM knowledge_nodes WHERE entity = ?1 LIMIT 1"
    },
    stmt_insert_node: database.CachedStatement = .{ .sql =
        // OR IGNORE closes the cross-process race the SELECT-first dedup
        // cannot (two windows both miss, both insert): the unique
        // idx_knodes_entity swallows the loser's row.
        "INSERT OR IGNORE INTO knowledge_nodes (entity, entity_type, properties, source, created_at, updated_at) " ++
            "VALUES (?1, ?2, NULL, ?3, ?4, ?5)"
    },
    stmt_edge_exists: database.CachedStatement = .{ .sql =
        "SELECT rowid FROM knowledge_edges WHERE from_id = ?1 AND to_id = ?2 AND relation = ?3"
    },
    stmt_insert_edge: database.CachedStatement = .{ .sql =
        // OR IGNORE: the unique idx_kedges_triple arbitrates the
        // cross-process race the SELECT cannot.
        "INSERT OR IGNORE INTO knowledge_edges (from_id, to_id, relation, weight) VALUES (?1, ?2, ?3, ?4)"
    },
    stmt_count_nodes: database.CachedStatement = .{ .sql =
        "SELECT COUNT(*) FROM knowledge_nodes"
    },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db: *database.Database) Self {
        return .{ .allocator = allocator, .db = db };
    }

    /// Finalize the cached statements. Must run before the Database closes.
    pub fn deinit(self: *Self) void {
        self.stmt_find_node.deinit();
        self.stmt_insert_node.deinit();
        self.stmt_edge_exists.deinit();
        self.stmt_insert_edge.deinit();
        self.stmt_count_nodes.deinit();
    }

    /// Node id for an exact entity name, or null — wires LLM-extracted
    /// relations whose endpoint names may predate this session.
    pub fn findNodeId(self: *Self, entity: []const u8) ?i64 {
        var find = self.stmt_find_node.acquire(self.allocator, self.db) catch return null;
        find.bindText(1, entity) catch return null;
        if (find.step() catch false) return find.columnInt64(0);
        return null;
    }

    pub fn addNode(self: *Self, entity: []const u8, entity_type: EntityType, source: ?[]const u8) !i64 {
        // Entity dedup: the same entity text reused to return a fresh row
        // every session, so re-extraction grew the graph without bound.
        {
            var find = try self.stmt_find_node.acquire(self.allocator, self.db);
            try find.bindText(1, entity);
            if (try find.step()) return find.columnInt64(0);
        }
        const now = time_mod.nowMillis();
        var stmt = try self.stmt_insert_node.acquire(self.allocator, self.db);
        try stmt.bindText(1, entity);
        try stmt.bindText(2, @tagName(entity_type));
        if (source) |s| try stmt.bindText(3, s);
        try stmt.bindInt64(4, now);
        try stmt.bindInt64(5, now);
        if (try stmt.step()) return error.UnexpectedRow;
        // Resolve the id by entity — on a race-lost INSERT OR IGNORE,
        // lastInsertRowId is stale and would hand out the WRONG node.
        var find = try self.stmt_find_node.acquire(self.allocator, self.db);
        try find.bindText(1, entity);
        if (try find.step()) return find.columnInt64(0);
        return error.NodeInsertFailed;
    }

    pub fn addEdge(self: *Self, from_id: i64, to_id: i64, relation: []const u8, weight: f32) !void {
        // SELECT-first like addNode: extractSessionMemories re-runs over the
        // full history on every /clear and session end, and an unconditional
        // INSERT re-added the same co_extracted edges once per run — the
        // edge table grew without bound across sessions.
        var exists = try self.stmt_edge_exists.acquire(self.allocator, self.db);
        try exists.bindInt64(1, from_id);
        try exists.bindInt64(2, to_id);
        try exists.bindText(3, relation);
        if (try exists.step()) return; // edge already recorded

        var stmt = try self.stmt_insert_edge.acquire(self.allocator, self.db);
        try stmt.bindInt64(1, from_id);
        try stmt.bindInt64(2, to_id);
        try stmt.bindText(3, relation);
        try stmt.bindFloat(4, weight);
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
        try stmt.bindFloat(1, threshold);
        _ = try stmt.step();
        return @intCast(self.db.changes());
    }

    /// Get node count.
    pub fn nodeCount(self: *Self) !usize {
        var stmt = try self.stmt_count_nodes.acquire(self.allocator, self.db);
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
        try stmt.bindInt64(1, @intCast(limit));

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

    /// P5 π 周期扫描：孤立节点（零度）与断边（端点缺失——不该发生，
    /// 出现即提取链路有 bug）。结果缓存在 last_scan（/knowledge 直接读），
    /// cron 每 π 小时刷一次。
    pub const GraphHealth = struct {
        orphan_nodes: usize = 0,
        broken_edges: usize = 0,
        total_nodes: usize = 0,
        total_edges: usize = 0,
        /// 前几个孤立实体名（诊断用，调用方负责释放）。
        orphan_samples: [][]u8 = &.{},
        pub fn deinit(self: *GraphHealth, alloc: std.mem.Allocator) void {
            for (self.orphan_samples) |s| alloc.free(s);
            if (self.orphan_samples.len > 0) alloc.free(self.orphan_samples);
        }
    };

    pub fn scanHealth(self: *Self, alloc: std.mem.Allocator) GraphHealth {
        var health = GraphHealth{ .total_nodes = self.nodeCount() catch 0 };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // One allocator end-to-end: the list grows and toOwnedSlice's on
        // the SAME caller allocator (arena-grown buffers handed to another
        // allocator remap-corrupt).
        var samples: std.ArrayList([]u8) = .empty;
        defer samples.deinit(alloc);

        {
            // Orphans: nodes touched by no edge on either side.
            const sql = "SELECT n.id, n.entity FROM knowledge_nodes n " ++
                "WHERE NOT EXISTS (SELECT 1 FROM knowledge_edges e WHERE e.from_id = n.id) " ++
                "AND NOT EXISTS (SELECT 1 FROM knowledge_edges e WHERE e.to_id = n.id)";
            var st = database.Statement.prepare(a, self.db, sql) catch return health;
            defer st.finalize();
            while (st.step() catch false) {
                health.orphan_nodes += 1;
                if (samples.items.len < 5) {
                    const dup = alloc.dupe(u8, st.columnText(1)) catch continue;
                    samples.append(alloc, dup) catch alloc.free(dup);
                }
            }
        }
        {
            const sql = "SELECT COUNT(*) FROM knowledge_edges e " ++
                "WHERE NOT EXISTS (SELECT 1 FROM knowledge_nodes n WHERE n.id = e.from_id) " ++
                "OR NOT EXISTS (SELECT 1 FROM knowledge_nodes n WHERE n.id = e.to_id)";
            var st = database.Statement.prepare(a, self.db, sql) catch {
                health.orphan_samples = samples.toOwnedSlice(alloc) catch &.{};
                return health;
            };
            defer st.finalize();
            if (st.step() catch false) health.broken_edges = @intCast(st.columnInt64(0));
        }
        {
            const st2 = database.Statement.prepare(a, self.db, "SELECT COUNT(*) FROM knowledge_edges") catch {
                health.orphan_samples = samples.toOwnedSlice(alloc) catch &.{};
                return health;
            };
            defer st2.finalize();
            if (st2.step() catch false) health.total_edges = @intCast(st2.columnInt64(0));
        }
        health.orphan_samples = samples.toOwnedSlice(alloc) catch &.{};
        return health;
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
    defer kg.deinit();
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

test "scanHealth finds orphan nodes and reports clean graphs" {
    const alloc = std.testing.allocator;
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/zage_scan_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);
    var db = try database.Database.init(alloc, path);
    defer db.deinit();
    try db.runMigrations();
    var kg = KnowledgeGraph.init(alloc, &db);
    defer kg.deinit();

    // Two connected nodes + one orphan.
    const a = try kg.addNode("Zig", .technology, null);
    const b = try kg.addNode("Claude", .technology, null);
    _ = try kg.addNode("Lonely", .concept, null);
    _ = try kg.addEdge(a, b, "used_by", 0.9);

    var h = kg.scanHealth(alloc);
    defer h.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), h.total_nodes);
    try std.testing.expectEqual(@as(usize, 1), h.total_edges);
    try std.testing.expectEqual(@as(usize, 1), h.orphan_nodes);
    try std.testing.expectEqual(@as(usize, 0), h.broken_edges);
    try std.testing.expectEqual(@as(usize, 1), h.orphan_samples.len);
    try std.testing.expectEqualStrings("Lonely", h.orphan_samples[0]);
}
