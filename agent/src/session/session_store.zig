//! Session persistence — the P3 resume backbone. Every turn boundary the
//! REPL flushes new history messages into `.ziv/sessions.db` (one
//! transaction per flush, WAL mode via the shared Database wrapper), so a
//! /quit, a crash, or a fresh terminal can pick the conversation back up
//! with /resume — history INCLUDING tool_use/tool_result/thinking blocks,
//! plus the session's model and permission mode.
//!
//! Ownership discipline: every string entering an llm.ContentBlock from
//! here is heap-allocated by the caller's allocator (wire decoding uses an
//! arena and dupes out) — see docs/bug-patterns.md "字面量入 history 块".

const std = @import("std");
const llm = @import("../llm/mod.zig");
const database_mod = @import("../storage/database.zig");
const util_time = @import("../util/time.zig");
const logger = @import("../util/log.zig");
const json_tree = @import("../util/json_tree.zig");
const fs_ops = @import("../util/fs_ops.zig");
const auth = @import("../tools/auth_mode.zig");
const injection_mod = @import("../memory/injection.zig");

pub const SessionStore = struct {
    db: database_mod.Database,
    session_id: i64,
    /// How many leading history messages are already persisted — flush()
    /// inserts only the tail. /resume adopts the loaded count.
    persisted: usize = 0,
    exit_marked: bool = false,
    alloc: std.mem.Allocator,

    /// Open (or create) the store and start a NEW session row.
    /// Returns null when the database cannot be opened — persistence is a
    /// best-effort layer, the REPL must run without it.
    pub fn open(alloc: std.mem.Allocator, path: []const u8, cwd: []const u8, model: []const u8, mode: auth.PermissionMode) ?*SessionStore {
        const self = alloc.create(SessionStore) catch return null;
        self.* = .{
            .db = database_mod.Database.init(alloc, path) catch {
                alloc.destroy(self);
                return null;
            },
            .session_id = 0,
            .alloc = alloc,
        };
        self.ensureSchema() catch {
            self.db.deinit();
            alloc.destroy(self);
            return null;
        };
        self.session_id = self.insertSession(cwd, model, mode) catch {
            self.db.deinit();
            alloc.destroy(self);
            return null;
        };
        return self;
    }

    pub fn close(self: *SessionStore) void {
        self.db.deinit();
        self.alloc.destroy(self);
    }

    fn ensureSchema(self: *SessionStore) !void {
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS ziv_sessions (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    started_at INTEGER NOT NULL,
            \\    ended_at INTEGER,
            \\    clean_exit INTEGER NOT NULL DEFAULT 0,
            \\    cwd TEXT NOT NULL,
            \\    model TEXT NOT NULL,
            \\    permission_mode TEXT NOT NULL,
            \\    first_line TEXT,
            \\    resumed_from INTEGER
            \\);
        );
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS ziv_session_messages (
            \\    session_id INTEGER NOT NULL,
            \\    seq INTEGER NOT NULL,
            \\    role TEXT NOT NULL,
            \\    content_json TEXT NOT NULL,
            \\    ts INTEGER NOT NULL,
            \\    PRIMARY KEY (session_id, seq)
            \\);
        );
    }

    fn insertSession(self: *SessionStore, cwd: []const u8, model: []const u8, mode: auth.PermissionMode) !i64 {
        const qcwd = database_mod.Database.quoteString(self.alloc, cwd) catch return error.SessionSqlFailed;
        defer self.alloc.free(qcwd);
        const qmodel = database_mod.Database.quoteString(self.alloc, model) catch return error.SessionSqlFailed;
        defer self.alloc.free(qmodel);
        const q = std.fmt.allocPrint(self.alloc,
            "INSERT INTO ziv_sessions (started_at, cwd, model, permission_mode) VALUES ({d}, {s}, {s}, '{s}')",
            .{ util_time.nowMillis(), qcwd, qmodel, @tagName(mode) },
        ) catch return error.SessionSqlFailed;
        defer self.alloc.free(q);
        try self.db.exec(q);
        return self.db.lastInsertRowId();
    }

    /// Persist the not-yet-written tail of `history` in one transaction;
    /// update first_line on the session's first user text. Errors are
    /// logged and swallowed — losing a persistence write must never kill
    /// the conversation.
    pub fn flush(self: *SessionStore, history: []const llm.Message) void {
        // A bare system prompt is not a conversation: rows without user
        // turns never persist anything, so abandoned startup rows stay
        // message-less (and adopt() deletes them instead of leaving
        // "#N · 0 轮" noise in every listing).
        if (history.len == 0) return;
        if (history.len == 1 and history[0].role == .system) return;
        // History SHRANK below the persisted baseline — compaction
        // (summarize/phi), /undo or /rewind rewrote it; the rows on disk
        // no longer match ANY prefix of the live history and the
        // incremental contract is void. Without this branch the failure
        // is two-fold and silent: new turns (len < persisted) never
        // persist, and once len grows past the baseline again the flush
        // writes LIVE rows at seqs whose DB neighbors are the PRE-compaction
        // rows — a resumed session then stitches old-prefix + new-suffix
        // into semantic garbage. Rebuild from scratch instead (compaction
        // is rare; the write amplification is fine). /undo's ghost rows
        // (reverted turns haunting the next resume) vanish with it.
        if (history.len < self.persisted) {
            const del = std.fmt.allocPrint(self.alloc, "DELETE FROM ziv_session_messages WHERE session_id={d}", .{self.session_id}) catch return;
            defer self.alloc.free(del);
            self.db.exec("BEGIN") catch return;
            self.db.exec(del) catch {
                self.db.exec("ROLLBACK") catch {};
                return; // keep the old baseline — never write a mismatched mix
            };
            self.db.exec("COMMIT") catch {};
            self.persisted = 0;
        }
        if (self.persisted >= history.len) return;
        self.db.exec("BEGIN") catch return;
        var ok = true;
        var seq: usize = self.persisted;
        while (seq < history.len) : (seq += 1) {
            const msg = history[seq];
            const json = encodeMessage(self.alloc, msg) catch {
                ok = false;
                break;
            };
            defer self.alloc.free(json);
            const role = @tagName(msg.role);
            const qjson = database_mod.Database.quoteString(self.alloc, json) catch {
                ok = false;
                break;
            };
            defer self.alloc.free(qjson);
            const q = std.fmt.allocPrint(self.alloc,
                "INSERT OR REPLACE INTO ziv_session_messages (session_id, seq, role, content_json, ts) VALUES ({d}, {d}, '{s}', {s}, {d})",
                .{ self.session_id, seq, role, qjson, msg.timestamp },
            ) catch {
                ok = false;
                break;
            };
            defer self.alloc.free(q);
            self.db.exec(q) catch {
                ok = false;
                break;
            };
            // Denormalized listing excerpt: first user text block wins.
            if (seq == self.firstUserIndex(history)) {
                for (msg.content) |b| {
                    if (b != .text) continue;
                    // Byte-slicing a CJK headline at 48 splits a UTF-8 rune and stores
                    // INVALID UTF-8 (caught live: external readers choke on the
                    // column). Clamp to the nearest boundary first.
                    const cut = injection_mod.utf8Boundary(b.text, 48);
                    const head = b.text[0..cut];
                    const qhead = database_mod.Database.quoteString(self.alloc, head) catch break;
                    defer self.alloc.free(qhead);
                    const uq = std.fmt.allocPrint(self.alloc,
                        "UPDATE ziv_sessions SET first_line={s} WHERE id={d} AND first_line IS NULL",
                        .{ qhead, self.session_id },
                    ) catch break;
                    defer self.alloc.free(uq);
                    self.db.exec(uq) catch {};
                    break;
                }
            }
        }
        if (ok) {
            self.persisted = seq;
            self.db.exec("COMMIT") catch {};
        } else {
            self.db.exec("ROLLBACK") catch {};
        }
    }

    fn firstUserIndex(self: *SessionStore, history: []const llm.Message) ?usize {
        _ = self;
        for (history, 0..) |m, i| {
            if (m.role != .user) continue;
            for (m.content) |b| {
                if (b == .text) return i;
            }
        }
        return null;
    }

    /// Record the session outcome. Called explicitly on /quit and EOF; the
    /// REPL's fallback defer marks unclean if nothing ran (a killed process
    /// marks nothing at all — that NULL ended_at IS the crash signal).
    pub fn markExit(self: *SessionStore, clean: bool) void {
        if (self.exit_marked) return;
        self.exit_marked = true;
        const q = std.fmt.allocPrint(self.alloc,
            "UPDATE ziv_sessions SET ended_at={d}, clean_exit={d} WHERE id={d}",
            .{ util_time.nowMillis(), @as(u8, if (clean) 1 else 0), self.session_id },
        ) catch return;
        defer self.alloc.free(q);
        self.db.exec(q) catch {};
    }

    /// Continue an old session in THIS process: messages already in the DB
    /// stay, new turns append after them. The row opened at startup (which
    /// the user chose to abandon by resuming) is closed first — otherwise
    /// an empty "crashed" session haunts every later startup hint.
    pub fn adopt(self: *SessionStore, session_id: i64, persisted: usize) void {
        self.markExit(true);
        self.exit_marked = false;
        // The startup row the user abandoned by resuming: if nothing ever
        // flushed into it, DELETE it — a perpetual "#N · 0 轮 · (无消息)"
        // entry in every later listing is pure noise.
        const cleanup = std.fmt.allocPrint(self.alloc,
            "DELETE FROM ziv_sessions WHERE id={d} AND NOT EXISTS " ++
                "(SELECT 1 FROM ziv_session_messages WHERE session_id={d})",
            .{ self.session_id, self.session_id },
        ) catch null;
        if (cleanup) |q| {
            defer self.alloc.free(q);
            self.db.exec(q) catch {};
        }
        self.session_id = session_id;
        self.persisted = persisted;
        self.exit_marked = false;
        const q = std.fmt.allocPrint(self.alloc,
            "UPDATE ziv_sessions SET ended_at=NULL, clean_exit=0 WHERE id={d}",
            .{session_id},
        ) catch return;
        defer self.alloc.free(q);
        self.db.exec(q) catch {};
    }

    /// End the current row (a /clear starts a fresh conversation) and open
    /// a new one in the same store.
    pub fn rotate(self: *SessionStore, cwd: []const u8, model: []const u8, mode: auth.PermissionMode) void {
        self.markExit(true);
        self.session_id = self.insertSession(cwd, model, mode) catch return;
        self.persisted = 0;
        self.exit_marked = false;
    }
};

pub const SessionInfo = struct {
    id: i64,
    started_at: i64,
    ended_at: ?i64,
    clean: bool,
    model: []u8,
    permission_mode: []u8,
    first_line: ?[]u8,
    rounds: usize,
};

pub const SessionMeta = struct {
    model: []u8,
    permission_mode: []u8,
};

/// Most recent sessions, newest first, with per-session message counts.
pub fn listRecent(alloc: std.mem.Allocator, db: *database_mod.Database, limit: usize) ![]SessionInfo {
    var out: std.ArrayList(SessionInfo) = .empty;
    errdefer {
        for (out.items) |*s| freeInfo(alloc, s.*);
        out.deinit(alloc);
    }
    const sql = try std.fmt.allocPrint(alloc,
        "SELECT s.id, s.started_at, s.ended_at, s.clean_exit, s.model, s.permission_mode, s.first_line, " ++
            "(SELECT COUNT(*) FROM ziv_session_messages m WHERE m.session_id=s.id) AS rounds " ++
            "FROM ziv_sessions s ORDER BY s.id DESC LIMIT {d}",
        .{limit},
    );
    defer alloc.free(sql);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var st = try database_mod.Statement.prepare(arena.allocator(), db, sql);
    defer st.finalize();
    while (try st.step()) {
        const get = struct {
            fn dupe(a: std.mem.Allocator, s: []const u8) []u8 {
                return a.dupe(u8, s) catch @constCast("");
            }
        }.dupe;
        try out.append(alloc, .{
            .id = st.columnInt64(0),
            .started_at = st.columnInt64(1),
            // NULL detection via columnText: an EMPTY text IS the null
            // marker. The old condition (`columnInt64 != 0 or ...`) was
            // inverted — every NON-null ended_at read back as null, so all
            // cleanly-exited sessions showed "未正常退出" in /resume and
            // every startup raised a false crash-recovery hint (caught
            // live 2026-11-11: db row had ended_at set, the hint said
            // otherwise; the roundtrip test only asserted the NULL side).
            .ended_at = if (st.columnText(2).len == 0) null else st.columnInt64(2),
            .clean = st.columnInt64(3) != 0,
            .model = get(alloc, st.columnText(4)),
            .permission_mode = get(alloc, st.columnText(5)),
            .first_line = if (st.columnText(6).len == 0) null else get(alloc, st.columnText(6)),
            .rounds = @intCast(st.columnInt64(7)),
        });
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeInfo(alloc: std.mem.Allocator, s: SessionInfo) void {
    alloc.free(s.model);
    alloc.free(s.permission_mode);
    if (s.first_line) |f| alloc.free(f);
}

/// The most recent session that never got an exit mark — the crash-recovery
/// candidate shown at startup.
/// `exclude_id` is the session THIS process just opened — the caller wants
/// a PREVIOUS unclean session, not its own brand-new NULL-ended row.
pub fn lastUncleanSession(alloc: std.mem.Allocator, db: *database_mod.Database, exclude_id: i64) !?SessionInfo {
    const list = try listRecent(alloc, db, 8);
    defer {
        for (list) |*s| freeInfo(alloc, s.*);
        alloc.free(list);
    }
    for (list) |s| {
        if (s.id == exclude_id) continue;
        if (s.ended_at == null) return try dupInfo(alloc, s);
    }
    return null;
}

fn dupInfo(alloc: std.mem.Allocator, s: SessionInfo) !SessionInfo {
    return .{
        .id = s.id,
        .started_at = s.started_at,
        .ended_at = s.ended_at,
        .clean = s.clean,
        .model = try alloc.dupe(u8, s.model),
        .permission_mode = try alloc.dupe(u8, s.permission_mode),
        .first_line = if (s.first_line) |f| try alloc.dupe(u8, f) else null,
        .rounds = s.rounds,
    };
}

/// Load a session's messages (lossless: all four block kinds) — every
/// string heap-owned by `alloc`. Empty when the id is unknown.
pub fn loadMessages(alloc: std.mem.Allocator, db: *database_mod.Database, session_id: i64) ![]llm.Message {
    var out: std.ArrayList(llm.Message) = .empty;
    errdefer {
        for (out.items) |m| freeMessage(m, alloc);
        out.deinit(alloc);
    }
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sql = try std.fmt.allocPrint(alloc,
        "SELECT role, content_json FROM ziv_session_messages WHERE session_id={d} ORDER BY seq",
        .{session_id},
    );
    defer alloc.free(sql);
    var st = try database_mod.Statement.prepare(arena.allocator(), db, sql);
    defer st.finalize();
    while (try st.step()) {
        const role_txt = st.columnText(0);
        const role: llm.MessageRole = std.meta.stringToEnum(llm.MessageRole, role_txt) orelse .user;
        const msg = decodeMessage(alloc, role, st.columnText(1)) catch continue;
        try out.append(alloc, msg);
    }
    return out.toOwnedSlice(alloc);
}

pub fn metaOf(alloc: std.mem.Allocator, db: *database_mod.Database, session_id: i64) !SessionMeta {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sql = try std.fmt.allocPrint(alloc, "SELECT model, permission_mode FROM ziv_sessions WHERE id={d}", .{session_id});
    defer alloc.free(sql);
    var st = try database_mod.Statement.prepare(arena.allocator(), db, sql);
    defer st.finalize();
    if (!(try st.step())) return error.NoSuchSession;
    return .{
        .model = try alloc.dupe(u8, st.columnText(0)),
        .permission_mode = try alloc.dupe(u8, st.columnText(1)),
    };
}

pub fn freeMessage(msg: llm.Message, alloc: std.mem.Allocator) void {
    for (msg.content) |b| switch (b) {
        .text, .thinking => |t| alloc.free(t),
        .tool_use => |tu| {
            alloc.free(tu.id);
            alloc.free(tu.name);
            json_tree.freeJsonValue(alloc, tu.input);
        },
        .tool_result => |tr| {
            alloc.free(tr.tool_use_id);
            alloc.free(tr.content);
        },
    };
    alloc.free(@constCast(msg.content));
}

// ── wire format ──────────────────────────────────────────────────────

/// Wire mirror of a ContentBlock — field names stay tiny; the store is
/// machine-owned and versioned by schema, not read by humans.
const WireBlock = struct {
    t: []const u8, // "text" | "think" | "use" | "res"
    x: ?[]const u8 = null,
    id: ?[]const u8 = null,
    n: ?[]const u8 = null,
    in: ?std.json.Value = null,
    c: ?[]const u8 = null,
    e: bool = false,
};

const WireMessage = struct {
    blocks: []const WireBlock,
};

pub fn encodeMessage(alloc: std.mem.Allocator, msg: llm.Message) ![]u8 {
    var blocks: std.ArrayList(WireBlock) = .empty;
    defer blocks.deinit(alloc);
    for (msg.content) |b| {
        switch (b) {
            .text => |t| try blocks.append(alloc, .{ .t = "text", .x = t }),
            .thinking => |t| try blocks.append(alloc, .{ .t = "think", .x = t }),
            .tool_use => |tu| try blocks.append(alloc, .{ .t = "use", .id = tu.id, .n = tu.name, .in = tu.input }),
            .tool_result => |tr| try blocks.append(alloc, .{ .t = "res", .id = tr.tool_use_id, .c = tr.content, .e = tr.is_error }),
        }
    }
    const wire = WireMessage{ .blocks = blocks.items };
    return std.json.Stringify.valueAlloc(alloc, wire, .{ .emit_null_optional_fields = false });
}

/// Decode into DEEP-OWNED blocks — arena-parsed wire strings are duped so
/// the result obeys the history heap-ownership discipline.
pub fn decodeMessage(alloc: std.mem.Allocator, role: llm.MessageRole, json: []const u8) !llm.Message {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const wire = std.json.parseFromSliceLeaky(WireMessage, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    }) catch return error.DecodeFailed;
    const blocks = try alloc.alloc(llm.ContentBlock, wire.blocks.len);
    errdefer alloc.free(blocks);
    var filled: usize = 0;
    errdefer for (blocks[0..filled]) |b| {
        switch (b) {
            .text, .thinking => |t| alloc.free(t),
            .tool_use => |tu| {
                alloc.free(tu.id);
                alloc.free(tu.name);
                json_tree.freeJsonValue(alloc, tu.input);
            },
            .tool_result => |tr| {
                alloc.free(tr.tool_use_id);
                alloc.free(tr.content);
            },
        }
    };
    for (wire.blocks) |wb| {
        const block: llm.ContentBlock = blk: {
            if (std.mem.eql(u8, wb.t, "text")) {
                break :blk .{ .text = try alloc.dupe(u8, wb.x orelse "") };
            } else if (std.mem.eql(u8, wb.t, "think")) {
                break :blk .{ .thinking = try alloc.dupe(u8, wb.x orelse "") };
            } else if (std.mem.eql(u8, wb.t, "use")) {
                break :blk .{ .tool_use = .{
                    .id = try alloc.dupe(u8, wb.id orelse ""),
                    .name = try alloc.dupe(u8, wb.n orelse ""),
                    .input = try json_tree.dupeJsonValue(alloc, wb.in orelse .null),
                } };
            } else if (std.mem.eql(u8, wb.t, "res")) {
                break :blk .{ .tool_result = .{
                    .tool_use_id = try alloc.dupe(u8, wb.id orelse ""),
                    .content = try alloc.dupe(u8, wb.c orelse ""),
                    .is_error = wb.e,
                } };
            }
            break :blk .{ .text = try alloc.dupe(u8, "") };
        };
        blocks[filled] = block;
        filled += 1;
    }
    return .{ .role = role, .content = blocks, .timestamp = 0 };
}

// ── tests ────────────────────────────────────────────────────────────

fn tmpDbPath(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/ziv_sess_{d}.db", .{ util_time.tmpRoot(), util_time.nowMillis() }) catch unreachable;
}

test "session roundtrip: flush all four block kinds, resume loadMessages" {
    const alloc = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = tmpDbPath(&pbuf);
    defer _ = fs_ops.deleteFile(path);
    const store = SessionStore.open(alloc, path, "/tmp", "gpt-test", .accept_edits) orelse return error.TestUnexpectedResult;
    defer store.close();

    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeMessage(m, alloc);
        history.deinit(alloc);
    }
    // system text
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "SYSTEM") };
        try history.append(alloc, .{ .role = .system, .content = b, .timestamp = 1 });
    }
    // user with tool_use (JSON input) + thinking + tool_result + error flag
    {
        var obj: std.json.ObjectMap = .empty;
        // Map keys/values handed to freeJsonValue must be heap-owned too —
        // the literal-free bus error again (see bug-patterns.md).
        try obj.put(alloc, try alloc.dupe(u8, "command"), .{ .string = try alloc.dupe(u8, "ls -la /tmp") });
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .tool_use = .{
            .id = try alloc.dupe(u8, "tu-1"),
            .name = try alloc.dupe(u8, "Bash"),
            .input = .{ .object = obj },
        } };
        try history.append(alloc, .{ .role = .assistant, .content = b, .timestamp = 2 });
    }
    {
        const b = try alloc.alloc(llm.ContentBlock, 2);
        b[0] = .{ .thinking = try alloc.dupe(u8, "internal reasoning") };
        b[1] = .{ .text = try alloc.dupe(u8, "answer") };
        try history.append(alloc, .{ .role = .assistant, .content = b, .timestamp = 3 });
    }
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .tool_result = .{
            .tool_use_id = try alloc.dupe(u8, "tu-1"),
            .content = try alloc.dupe(u8, "file list output"),
            .is_error = true,
        } };
        try history.append(alloc, .{ .role = .user, .content = b, .timestamp = 4 });
    }

    store.flush(history.items);
    try std.testing.expectEqual(@as(usize, 4), store.persisted);
    // Idempotent: nothing new to write.
    store.flush(history.items);
    try std.testing.expectEqual(@as(usize, 4), store.persisted);

    store.markExit(true);

    const loaded = try loadMessages(alloc, &store.db, store.session_id);
    defer {
        for (loaded) |m| freeMessage(m, alloc);
        alloc.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 4), loaded.len);
    try std.testing.expect(loaded[0].role == .system);
    try std.testing.expectEqualStrings("SYSTEM", loaded[0].content[0].text);
    try std.testing.expectEqualStrings("tu-1", loaded[1].content[0].tool_use.id);
    try std.testing.expectEqualStrings("Bash", loaded[1].content[0].tool_use.name);
    const in_val = loaded[1].content[0].tool_use.input;
    try std.testing.expect(in_val == .object);
    try std.testing.expectEqualStrings("ls -la /tmp", in_val.object.get("command").?.string);
    try std.testing.expectEqualStrings("internal reasoning", loaded[2].content[0].thinking);
    try std.testing.expectEqualStrings("answer", loaded[2].content[1].text);
    try std.testing.expect(loaded[3].content[0].tool_result.is_error);

    const list = try listRecent(alloc, &store.db, 5);
    defer {
        for (list) |*s| freeInfo(alloc, s.*);
        alloc.free(list);
    }
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(usize, 4), list[0].rounds);
    try std.testing.expect(list[0].clean);
    // The inversion bug's blind spot: a SET ended_at must read back
    // non-null (every clean exit used to surface as "未正常退出").
    try std.testing.expect(list[0].ended_at != null);
    try std.testing.expectEqualStrings("gpt-test", list[0].model);
}

test "crash signal: unflushed exit leaves ended_at NULL for recovery" {
    const alloc = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = tmpDbPath(&pbuf);
    defer _ = fs_ops.deleteFile(path);
    const store = SessionStore.open(alloc, path, "/tmp", "m", .default) orelse return error.TestUnexpectedResult;

    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeMessage(m, alloc);
        history.deinit(alloc);
    }
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "hello before the crash") };
        try history.append(alloc, .{ .role = .user, .content = b, .timestamp = 1 });
    }
    store.flush(history.items);
    // NO markExit — the process "died". Reopen the same file raw.
    store.db.deinit();
    store.alloc.destroy(store);

    var db2 = try database_mod.Database.init(alloc, path);
    defer db2.deinit();
    const unclean = try lastUncleanSession(alloc, &db2, -1);
    defer if (unclean) |u| {
        alloc.free(u.model);
        alloc.free(u.permission_mode);
        if (u.first_line) |f| alloc.free(f);
    };
    try std.testing.expect(unclean != null);
    try std.testing.expect(unclean.?.ended_at == null);
    try std.testing.expectEqualStrings("hello before the crash", unclean.?.first_line.?);
    const msgs = try loadMessages(alloc, &db2, unclean.?.id);
    defer {
        for (msgs) |m| freeMessage(m, alloc);
        alloc.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("hello before the crash", msgs[0].content[0].text);
}

test "adopt + rotate: continue a session, /clear starts a fresh row" {
    const alloc = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = tmpDbPath(&pbuf);
    defer _ = fs_ops.deleteFile(path);
    const store = SessionStore.open(alloc, path, "/tmp", "m", .default) orelse return error.TestUnexpectedResult;
    defer store.close();

    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeMessage(m, alloc);
        history.deinit(alloc);
    }
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "original turn") };
        try history.append(alloc, .{ .role = .user, .content = b, .timestamp = 1 });
    }
    store.flush(history.items);
    const first_id = store.session_id;
    store.markExit(true);

    // "resume": adopt the closed session, append a follow-up turn.
    store.adopt(first_id, 1);
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "follow-up turn") };
        try history.append(alloc, .{ .role = .user, .content = b, .timestamp = 2 });
    }
    store.flush(history.items); // persists only the tail
    try std.testing.expectEqual(@as(usize, 2), store.persisted);

    const msgs = try loadMessages(alloc, &store.db, first_id);
    defer {
        for (msgs) |m| freeMessage(m, alloc);
        alloc.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqualStrings("follow-up turn", msgs[1].content[0].text);

    // /clear rotates to a brand-new row.
    store.rotate("/tmp", "m", .default);
    try std.testing.expect(store.session_id != first_id);
    try std.testing.expectEqual(@as(usize, 0), store.persisted);
    const list = try listRecent(alloc, &store.db, 5);
    defer {
        for (list) |*s| freeInfo(alloc, s.*);
        alloc.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expect(list[0].id == store.session_id); // newest first
    try std.testing.expect(list[1].clean); // rotated-out row ended cleanly
}

test "history shrink (compaction/undo): flush rebuilds, later turns persist" {
    const alloc = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const path = tmpDbPath(&pbuf);
    defer _ = fs_ops.deleteFile(path);
    const store = SessionStore.open(alloc, path, "/tmp", "gpt-test", .default) orelse return error.TestUnexpectedResult;
    defer store.close();

    var history: std.ArrayList(llm.Message) = .empty;
    defer {
        for (history.items) |m| freeMessage(m, alloc);
        history.deinit(alloc);
    }
    // [system, user, assistant] — 3 rows persisted.
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "SYSTEM") };
        try history.append(alloc, .{ .role = .system, .content = b, .timestamp = 1 });
    }
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "原始问题") };
        try history.append(alloc, .{ .role = .user, .content = b, .timestamp = 2 });
    }
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "原始回答") };
        try history.append(alloc, .{ .role = .assistant, .content = b, .timestamp = 3 });
    }
    store.flush(history.items);
    try std.testing.expectEqual(@as(usize, 3), store.persisted);

    // Compaction rewrites to [system, summary] — len(2) < persisted(3):
    // the old incremental-only flush returned here and the summary (and
    // every later turn) silently never persisted.
    for (history.items) |m| freeMessage(m, alloc);
    history.clearRetainingCapacity();
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "SYSTEM") };
        try history.append(alloc, .{ .role = .system, .content = b, .timestamp = 1 });
    }
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "[summary] 摘要") };
        try history.append(alloc, .{ .role = .user, .content = b, .timestamp = 4 });
    }
    store.flush(history.items);
    try std.testing.expectEqual(@as(usize, 2), store.persisted);

    // Post-compaction turns must append (the len-past-baseline mixup guard).
    {
        const b = try alloc.alloc(llm.ContentBlock, 1);
        b[0] = .{ .text = try alloc.dupe(u8, "新回答") };
        try history.append(alloc, .{ .role = .assistant, .content = b, .timestamp = 5 });
    }
    store.flush(history.items);
    try std.testing.expectEqual(@as(usize, 3), store.persisted);

    const loaded = try loadMessages(alloc, &store.db, store.session_id);
    defer {
        for (loaded) |m| freeMessage(m, alloc);
        alloc.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    try std.testing.expect(std.mem.indexOf(u8, loaded[1].content[0].text, "summary") != null);
    try std.testing.expectEqualStrings("新回答", loaded[2].content[0].text);
    // The pre-compaction ghosts are gone.
    try std.testing.expect(std.mem.indexOf(u8, loaded[1].content[0].text, "原始") == null);
}
