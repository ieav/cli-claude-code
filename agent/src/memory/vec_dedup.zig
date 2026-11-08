//! 语义去重（2026-11-10 ② sqlite-vec）：记忆入库前经向量 KNN 查重，
//! 替代纯字符串比较——同一件事的两种说法（「退出太慢」vs「/quit 等
//! 待过长」）字符串不重、语义重。向量 = 本地 hash 嵌入（util/embedding，
//! 256 维，零网络），KNN 由内嵌 sqlite-vec 的 vec0 虚表完成。
//! 降级契约：vec_ready=false 时全部函数变 no-op（旧库/异常环境不受影响）。

const std = @import("std");
const database = @import("../storage/database.zig");
const c = @import("../storage/sqlite_c.zig");
const embedding = @import("../util/embedding.zig");

/// 重复判定阈值：hash 嵌入的 cosine 相似度 ≥ 此值视为同一语义。
/// 实测定标（2026-11-10，256 维 bag-of-hash bigram）：
///   改写对 0.45 / 0.40（「退出速度太慢…」vs「退出耗时太长…」）
///   相似洞察 0.49（「工具真实失败率过高」vs「工具失败率高」）
///   无关对 0.10 / 0.07
/// 分离度 ~4x——0.35 落在带余量的分界点（阈值初稿 0.92 是拍脑袋，
/// 实测即错：那套嵌入的量级根本到不了 0.9）。
pub const DUP_THRESHOLD: f32 = 0.35;

/// vec0 虚表（memory_id 与 memories.id 的 hex 对齐）。
const TABLE_SQL =
    "CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories USING vec0(" ++
    "memory_id TEXT PRIMARY KEY, embedding float[" ++ "256" ++ "] distance_metric=cosine);";

/// 幂等建表。返回 false = 向量特性不可用（未注册/建表失败）。
pub fn ensureTable(db: *database.Database) bool {
    if (!db.vec_ready) return false;
    return c.sqlite3_exec(db.db, TABLE_SQL, null, null, null) == c.SQLITE_OK;
}

fn hexId(id: [16]u8, out: *[32]u8) []const u8 {
    const hex = "0123456789abcdef";
    for (id, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xF];
    }
    return out[0..32];
}

/// 记忆入库后建索引（best-effort：失败不影响主流程）。
pub fn indexMemory(db: *database.Database, id: [16]u8, content: []const u8) void {
    if (!ensureTable(db)) return;
    var vec: [embedding.DIMS]f32 = undefined;
    embedding.embedInto(&vec, content);
    var hex_buf: [32]u8 = undefined;
    const hex = hexId(id, &hex_buf);

    const ins_sql = "INSERT OR REPLACE INTO vec_memories(memory_id, embedding) VALUES (?, ?)";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.db, ins_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hex.ptr, 32, c.SQLITE_STATIC);
    const bytes = std.mem.sliceAsBytes(&vec);
    _ = c.sqlite3_bind_blob(stmt, 2, bytes.ptr, @intCast(bytes.len), c.SQLITE_STATIC);
    _ = c.sqlite3_step(stmt);
}

/// 语义查重：库中已有与 content 足够相似的记忆 → true。
/// 无向量特性/查询失败 → false（fail-open：不因降级误杀入库）。
pub fn isSemanticDup(db: *database.Database, content: []const u8) bool {
    if (!ensureTable(db)) return false;
    var vec: [embedding.DIMS]f32 = undefined;
    embedding.embedInto(&vec, content);
    const q_sql = "SELECT distance FROM vec_memories WHERE embedding MATCH ? AND k = 1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.db, q_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_finalize(stmt);
    const bytes = std.mem.sliceAsBytes(&vec);
    _ = c.sqlite3_bind_blob(stmt, 1, bytes.ptr, @intCast(bytes.len), c.SQLITE_STATIC);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return false;
    // vec0 cosine 的 distance = 1 - cosine → 阈值换算。
    const dist: f32 = @floatCast(c.sqlite3_column_double(stmt, 0));
    return (1.0 - dist) >= DUP_THRESHOLD;
}

/// 删除记忆时同步清向量（best-effort）。
pub fn forgetMemory(db: *database.Database, id: [16]u8) void {
    if (!db.vec_ready) return;
    var hex_buf: [32]u8 = undefined;
    const hex = hexId(id, &hex_buf);
    const del_sql = "DELETE FROM vec_memories WHERE memory_id = ?";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.db, del_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hex.ptr, 32, c.SQLITE_STATIC);
    _ = c.sqlite3_step(stmt);
}

// ──── Tests：真库 + 真扩展 ────

test "vec_dedup: paraphrase detected, distinct not, degrade safe" {
    const alloc = std.testing.allocator;
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&pbuf, "/tmp/ziv_vec_test_{d}.db", .{@import("../util/time.zig").nowMillis()});
    // 测试库留在 /tmp（无 Io 实例做清理——残留无害）。
    var db = try database.Database.init(alloc, db_path);
    defer db.deinit();

    try std.testing.expect(db.vec_ready); // 扩展注册成功（测试环境铁律）

    const id1 = [_]u8{1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1};
    indexMemory(&db, id1, "退出速度太慢了，每次都要等很久才能完全退出");
    // 改写（同一语义、不同措辞）→ 查重命中。
    try std.testing.expect(isSemanticDup(&db, "退出耗时太长，每次 /quit 都要等待很久"));
    // 无关内容 → 不命中。
    try std.testing.expect(!isSemanticDup(&db, "quicksort 的最坏复杂度是 n 方"));
    // 删除后不再命中。
    forgetMemory(&db, id1);
    try std.testing.expect(!isSemanticDup(&db, "退出耗时太长，每次 /quit 都要等待很久"));
}
