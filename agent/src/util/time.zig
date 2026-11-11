/// Time utilities — timestamps, formatting, durations.
/// Compatible with Zig 0.16.
const std = @import("std");
const builtin = @import("builtin");

/// Get current Unix timestamp in seconds.
pub fn nowSeconds() i64 {
    return @divTrunc(nowMillis(), 1000);
}

/// Get current Unix timestamp in milliseconds.
const win32_time = struct {
    pub extern "kernel32" fn GetSystemTimeAsFileTime(lpFileTime: *std.os.windows.FILETIME) callconv(.winapi) void;
    pub extern "kernel32" fn Sleep(dwMilliseconds: std.os.windows.DWORD) callconv(.winapi) void;
};


pub fn nowMillis() i64 {
    if (builtin.os.tag == .windows) {
        var ft: std.os.windows.FILETIME = undefined;
        win32_time.GetSystemTimeAsFileTime(&ft);
        const t: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        return @intCast(t / 10_000 - 11_644_473_600_000); // 100ns→ms, 1601→1970 epoch
    }
    var ts: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts);
    if (rc != 0) return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Format a Unix timestamp as ISO 8601 string.
/// Caller owns the returned slice.
pub fn formatIso(allocator: std.mem.Allocator, timestamp_ms: i64) ![]u8 {
    const epoch_seconds = @divTrunc(timestamp_ms, 1000);
    const epoch_days = @divTrunc(epoch_seconds, 86400);

    var days: i32 = @intCast(epoch_days);
    var year: i32 = 1970;
    while (true) {
        const days_in_year: i32 = if (isLeapYear(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const month_days = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: i32 = 0;
    for (month_days, 0..) |md, i| {
        const adjusted: i32 = if (i == 1 and isLeapYear(year)) md + 1 else md;
        if (days < adjusted) {
            month = @intCast(i);
            break;
        }
        days -= adjusted;
    }
    const day = days + 1;

    const time_of_day = @rem(epoch_seconds, 86400);
    const hour = @divTrunc(time_of_day, 3600);
    const minute = @divTrunc(@rem(time_of_day, 3600), 60);
    const second = @rem(time_of_day, 60);

    return allocator.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        // Unsigned: 0.17 emits a '+' sign for zero-padded signed integers.
        @as(u32, @intCast(year)),
        @as(u32, @intCast(month + 1)),
        @as(u32, @intCast(day)),
        @as(u32, @intCast(hour)),
        @as(u32, @intCast(minute)),
        @as(u32, @intCast(second)),
    });
}

fn isLeapYear(year: i32) bool {
    return (@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0);
}

/// Temp-dir root for tests/scratch: $TMPDIR (posix) / %TEMP% (windows),
/// falling back to /tmp. Replaces hardcoded "/tmp/..." literals.
pub fn tmpRoot() []const u8 {
    const env = @import("env.zig");
    if (@import("builtin").os.tag == .windows) {
        if (env.get("TEMP")) |t| return t;
    }
    if (env.get("TMPDIR")) |t| return t;
    return "/tmp";
}

/// Sleep for a given number of milliseconds (std.time.sleep is gone in
/// 0.17 — nanosleep directly, same as the thread pool's poll backoff).
pub fn sleepMs(ms: u64) void {
    if (builtin.os.tag == .windows) {
            win32_time.Sleep(@intCast(ms));
            return;
        }
        var req: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&req, null);
}

/// Local date/time parts. `weekday` is 0=Sunday .. 6=Saturday.
pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    weekday: u8,
};

const Ctm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(t: *const i64, tm: *Ctm) ?*Ctm;
// mingw crt: same tm layout, different symbol (posix layer is absent).
extern "c" fn _localtime64(t: *const i64) ?*Ctm;

/// Local time via C localtime_r — honors the host timezone without parsing
/// zoneinfo. libc is already linked (SQLite dep).
pub fn localDateTime(ts_ms: i64) DateTime {
    const secs: i64 = @divTrunc(ts_ms, 1000);
    if (builtin.os.tag == .windows) {
        // _localtime64 stores into a static buffer and returns it — copy
        // out immediately (single-threaded callers only; matches usage).
        if (_localtime64(&secs)) |tp| {
            const tm = tp.*;
            return .{
                .year = @intCast(tm.year + 1900),
                .month = @intCast(tm.mon + 1),
                .day = @intCast(tm.mday),
                .hour = @intCast(tm.hour),
                .minute = @intCast(tm.min),
                .weekday = @intCast(tm.wday),
            };
        }
        return .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .weekday = 4 };
    }
    var tm: Ctm = undefined;
    if (localtime_r(&secs, &tm) == null) {
        // Epoch (1970-01-01) was a Thursday.
        return .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .weekday = 4 };
    }
    return .{
        .year = @intCast(tm.year + 1900),
        .month = @intCast(tm.mon + 1),
        .day = @intCast(tm.mday),
        .hour = @intCast(tm.hour),
        .minute = @intCast(tm.min),
        .weekday = @intCast(tm.wday),
    };
}

/// Calculate elapsed milliseconds since a start timestamp.
pub fn elapsedSince(start_ms: i64) i64 {
    return nowMillis() - start_ms;
}

test "formatIso" {
    const alloc = std.testing.allocator;
    const iso = try formatIso(alloc, 1700000000000);
    defer alloc.free(iso);
    try std.testing.expect(iso.len == 20);
}

test "localDateTime sanity" {
    const dt = localDateTime(nowMillis());
    try std.testing.expect(dt.year >= 2026);
    try std.testing.expect(dt.month >= 1 and dt.month <= 12);
    try std.testing.expect(dt.day >= 1 and dt.day <= 31);
    try std.testing.expect(dt.weekday <= 6);
    // Fixed instant: 2026-10-28 12:34:56 UTC — local date may shift a day
    // with timezone, but the parts must be internally consistent.
    const fixed = localDateTime(1793678096000);
    try std.testing.expect(fixed.year == 2026 or fixed.year == 2027 or fixed.year == 2025);
}
