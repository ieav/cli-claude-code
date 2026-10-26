/// Time utilities — timestamps, formatting, durations.
/// Compatible with Zig 0.16.
const std = @import("std");

/// Get current Unix timestamp in seconds.
pub fn nowSeconds() i64 {
    return @divTrunc(nowMillis(), 1000);
}

/// Get current Unix timestamp in milliseconds.
pub fn nowMillis() i64 {
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

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
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

/// Sleep for a given number of milliseconds.
pub fn sleepMs(ms: u64) void {
    std.time.sleep(ms * std.time.ns_per_ms);
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
