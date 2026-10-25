/// Manual SQLite3 C API bindings.
/// Zig 0.17 removed @cImport; this file declares only the subset the project
/// uses. Extend with new extern declarations as more of the API is needed.
pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

// Result codes used by this project.
pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

/// Callback type for sqlite3_exec; null when no row callback is wanted.
pub const ExecCallback = ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) ?*anyopaque;

pub extern fn sqlite3_open(filename: [*:0]const u8, pp_db: *?*sqlite3) c_int;
pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
pub extern fn sqlite3_exec(
    db: ?*sqlite3,
    sql: [*:0]const u8,
    callback: ExecCallback,
    callback_arg: ?*anyopaque,
    err_msg: ?*?[*:0]u8,
) c_int;
pub extern fn sqlite3_free(ptr: ?*anyopaque) void;
pub extern fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;
pub extern fn sqlite3_prepare_v2(
    db: ?*sqlite3,
    z_sql: [*:0]const u8,
    n_byte: c_int,
    pp_stmt: *?*sqlite3_stmt,
    pz_tail: ?*?[*:0]const u8,
) c_int;
pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, i_col: c_int) ?[*:0]const u8;
