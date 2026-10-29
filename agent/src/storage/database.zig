/// SQLite database wrapper via C interop.
/// Manages connections, migrations, and prepared statements.
const std = @import("std");
const time_mod = @import("../util/time.zig");
const fs_ops = @import("../util/fs_ops.zig");

const c = @import("sqlite_c.zig");

pub const Database = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,
    path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        var db: ?*c.sqlite3 = null;
        const path_c = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_c);
        // Owned copy taken BEFORE open: dupe-after-open leaked the handle
        // when the copy failed (open/close asymmetry on the error path).
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const rc = c.sqlite3_open(path_c.ptr, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.DatabaseOpenFailed;
        }

        // Enable WAL mode for better concurrent reads
        _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null);
        _ = c.sqlite3_exec(db, "PRAGMA foreign_keys=ON;", null, null, null);
        // Concurrent windows: two ziv processes in one working directory
        // write this same DB. WAL serializes writers safely, but with the
        // default busy_timeout=0 the loser got an immediate "database is
        // locked" — measured: a concurrent writer dropped 100% of its rows.
        // 2 s of patient retry makes simultaneous exits/clears coexist.
        _ = c.sqlite3_exec(db, "PRAGMA busy_timeout=2000;", null, null, null);

        return .{
            .allocator = allocator,
            .db = db,
            .path = owned_path,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
        }
        self.allocator.free(self.path);
    }

    /// Get the last inserted row ID.
    pub fn lastInsertRowId(self: *Self) i64 {
        const db = self.db orelse return 0;
        return c.sqlite3_last_insert_rowid(db);
    }

    /// Rows changed by the most recent INSERT/UPDATE/DELETE on this connection.
    pub fn changes(self: *Self) c_int {
        const db = self.db orelse return 0;
        return c.sqlite3_changes(db);
    }

    /// Execute a raw SQL statement (no return data).
    pub fn exec(self: *Self, sql: []const u8) !void {
        const db = self.db orelse return error.DatabaseNotOpen;
        const sql_c = try self.allocator.dupeSentinel(u8, sql, 0);
        defer self.allocator.free(sql_c);

        var err_msg: ?[*:0]u8 = null;
        const rc = c.sqlite3_exec(db, sql_c.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                std.debug.print("SQLite error: {s}\n", .{msg});
                c.sqlite3_free(@ptrCast(msg));
            }
            return error.DatabaseExecFailed;
        }
    }

    /// Check database integrity.
    pub fn checkIntegrity(self: *Self) !bool {
        const db = self.db orelse return error.DatabaseNotOpen;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, null);
        if (rc != c.SQLITE_OK) return false;
        defer _ = c.sqlite3_finalize(stmt);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc == c.SQLITE_ROW) {
            const text = c.sqlite3_column_text(stmt, 0) orelse return false;
            return std.mem.eql(u8, std.mem.sliceTo(text, 0), "ok");
        }
        return false;
    }

    /// Run all pending migrations.
    pub fn runMigrations(self: *Self) !void {
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS conversations (
            \\    id BLOB(16) PRIMARY KEY,
            \\    started_at INTEGER NOT NULL,
            \\    ended_at INTEGER,
            \\    model TEXT NOT NULL,
            \\    provider TEXT NOT NULL,
            \\    summary TEXT
            \\);
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS messages (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    conversation_id BLOB(16) NOT NULL REFERENCES conversations(id),
            \\    role TEXT NOT NULL CHECK(role IN ('system','user','assistant','tool')),
            \\    content TEXT NOT NULL,
            \\    tool_calls TEXT,
            \\    timestamp INTEGER NOT NULL,
            \\    token_count INTEGER
            \\);
        );
        try self.exec("CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, timestamp);");
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS embeddings (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    entity_type TEXT NOT NULL,
            \\    entity_id TEXT NOT NULL,
            \\    embedding BLOB NOT NULL,
            \\    model TEXT NOT NULL,
            \\    dimensions INTEGER NOT NULL,
            \\    created_at INTEGER NOT NULL
            \\);
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS memories (
            \\    id BLOB(16) PRIMARY KEY,
            \\    type TEXT NOT NULL CHECK(type IN ('user','feedback','project','reference')),
            \\    scope TEXT NOT NULL DEFAULT 'private',
            \\    name TEXT NOT NULL,
            \\    description TEXT NOT NULL,
            \\    content TEXT NOT NULL,
            \\    access_count INTEGER DEFAULT 0,
            \\    embedding_id INTEGER REFERENCES embeddings(id),
            \\    created_at INTEGER NOT NULL,
            \\    updated_at INTEGER NOT NULL
            \\);
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS knowledge_nodes (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    entity TEXT NOT NULL,
            \\    entity_type TEXT NOT NULL,
            \\    properties TEXT,
            \\    source TEXT,
            \\    embedding_id INTEGER REFERENCES embeddings(id),
            \\    created_at INTEGER NOT NULL,
            \\    updated_at INTEGER NOT NULL
            \\);
        );
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS knowledge_edges (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    from_id INTEGER NOT NULL REFERENCES knowledge_nodes(id),
            \\    to_id INTEGER NOT NULL REFERENCES knowledge_nodes(id),
            \\    relation TEXT NOT NULL,
            \\    weight REAL DEFAULT 1.0,
            \\    properties TEXT
            \\);
        );
        try self.exec("CREATE INDEX IF NOT EXISTS idx_nodes_entity ON knowledge_nodes(entity);");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_edges_from ON knowledge_edges(from_id);");
        try self.exec("CREATE INDEX IF NOT EXISTS idx_edges_to ON knowledge_edges(to_id);");

        // Concurrent windows, part 2: enforce graph uniqueness at the SCHEMA
        // level. SELECT-then-INSERT dedup cannot close a cross-process race
        // (both windows miss, both insert). Order is FK-safe: edges touching
        // duplicate nodes go first, then the duplicate nodes themselves,
        // then duplicate edges, then the unique indexes.
        try self.exec(
            \\DELETE FROM knowledge_edges
            \\ WHERE from_id IN (SELECT id FROM knowledge_nodes
            \\                    WHERE id NOT IN (SELECT MIN(id) FROM knowledge_nodes GROUP BY entity))
            \\    OR to_id   IN (SELECT id FROM knowledge_nodes
            \\                    WHERE id NOT IN (SELECT MIN(id) FROM knowledge_nodes GROUP BY entity));
        );
        try self.exec("DELETE FROM knowledge_nodes WHERE id NOT IN (SELECT MIN(id) FROM knowledge_nodes GROUP BY entity);");
        try self.exec("DELETE FROM knowledge_edges WHERE from_id NOT IN (SELECT id FROM knowledge_nodes) OR to_id NOT IN (SELECT id FROM knowledge_nodes);");
        try self.exec("DELETE FROM knowledge_edges WHERE id NOT IN (SELECT MIN(id) FROM knowledge_edges GROUP BY from_id, to_id, relation);");
        try self.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_knodes_entity ON knowledge_nodes(entity);");
        try self.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_kedges_triple ON knowledge_edges(from_id, to_id, relation);");
    }

    /// Get the underlying sqlite3 pointer for advanced operations.
    pub fn getRawDb(self: *Self) ?*c.sqlite3 {
        return self.db;
    }

    /// Escape and quote a string for safe SQL interpolation.
    /// Wraps the string in single quotes and doubles any embedded single quotes.
    /// Caller owns the returned memory.
    pub fn quoteString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        var quote_count: usize = 0;
        for (s) |ch| {
            if (ch == '\'') quote_count += 1;
        }
        const result = try allocator.alloc(u8, s.len + quote_count + 2);
        result[0] = '\'';
        var j: usize = 1;
        for (s) |ch| {
            if (ch == '\'') {
                result[j] = '\'';
                result[j + 1] = '\'';
                j += 2;
            } else {
                result[j] = ch;
                j += 1;
            }
        }
        result[j] = '\'';
        return result[0 .. j + 1];
    }
};

/// Prepared statement wrapper. SQL parameters are bound by index (?1, ?2, ...)
/// so user-controlled data never touches the SQL text itself.
pub const Statement = struct {
    allocator: std.mem.Allocator,
    stmt: *c.sqlite3_stmt,
    db: *Database,

    const Self = @This();

    pub fn prepare(allocator: std.mem.Allocator, db: *Database, sql: []const u8) !Self {
        const raw = db.db orelse return error.DatabaseNotOpen;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(raw, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.StatementPrepareFailed;
        return .{ .allocator = allocator, .stmt = stmt.?, .db = db };
    }

    pub fn bindText(self: Self, idx: c_int, text: []const u8) !void {
        if (c.sqlite3_bind_text(self.stmt, idx, text.ptr, @intCast(text.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
    }

    pub fn bindInt64(self: Self, idx: c_int, value: i64) !void {
        if (c.sqlite3_bind_int64(self.stmt, idx, value) != c.SQLITE_OK)
            return error.BindFailed;
    }

    pub fn bindFloat(self: Self, idx: c_int, value: f64) !void {
        if (c.sqlite3_bind_double(self.stmt, idx, value) != c.SQLITE_OK)
            return error.BindFailed;
    }

    pub fn bindBlob(self: Self, idx: c_int, bytes: []const u8) !void {
        if (c.sqlite3_bind_blob(self.stmt, idx, bytes.ptr, @intCast(bytes.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
    }

    /// Returns true when a row is available, false when iteration is done.
    pub fn step(self: Self) !bool {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.StatementStepFailed;
    }

    /// Returned slice points into SQLite's internal buffer; copy it before
    /// the next step()/finalize() call.
    pub fn columnText(self: Self, idx: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, idx) orelse return &.{};
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, idx));
        return ptr[0..len];
    }

    /// Same lifetime caveat as columnText.
    pub fn columnBlob(self: Self, idx: c_int) []const u8 {
        const ptr = c.sqlite3_column_blob(self.stmt, idx) orelse return &.{};
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, idx));
        const bytes: [*]const u8 = @ptrCast(ptr);
        return bytes[0..len];
    }

    pub fn columnInt64(self: Self, idx: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, idx);
    }

    pub fn finalize(self: Self) void {
        _ = c.sqlite3_finalize(self.stmt);
    }
};

test "Database init and migration" {
    var tmp_dir_name: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp_dir_name, "/tmp/zage_test_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = fs_ops.deleteFile(path);

    var db = try Database.init(std.testing.allocator, path);
    defer db.deinit();

    try db.runMigrations();
    try std.testing.expect(try db.checkIntegrity());
}
