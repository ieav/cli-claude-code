/// SQLite database wrapper via C interop.
/// Manages connections, migrations, and prepared statements.
const std = @import("std");
const time_mod = @import("../util/time.zig");

const c = @import("sqlite_c.zig");

pub const Database = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,
    path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        var db: ?*c.sqlite3 = null;
        const path_c = try allocator.dupeZ(u8, path);
        defer allocator.free(path_c);

        const rc = c.sqlite3_open(path_c.ptr, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| c.sqlite3_close(d);
            return error.DatabaseOpenFailed;
        }

        // Enable WAL mode for better concurrent reads
        _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null);
        _ = c.sqlite3_exec(db, "PRAGMA foreign_keys=ON;", null, null, null);

        return .{
            .allocator = allocator,
            .db = db,
            .path = try allocator.dupe(u8, path),
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

    /// Execute a raw SQL statement (no return data).
    pub fn exec(self: *Self, sql: []const u8) !void {
        const db = self.db orelse return error.DatabaseNotOpen;
        const sql_c = try self.allocator.dupeZ(u8, sql);
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
            const text = c.sqlite3_column_text(stmt, 0);
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

test "Database init and migration" {
    var tmp_dir_name: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp_dir_name, "/tmp/zage_test_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer std.posix.unlink(path) catch {};

    var db = try Database.init(std.testing.allocator, path);
    defer db.deinit();

    try db.runMigrations();
    try std.testing.expect(try db.checkIntegrity());
}
