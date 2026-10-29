/// Formatting utilities — numbers, tokens, costs, durations.
const std = @import("std");

/// Format a byte count as human-readable (e.g., "1.5 MB").
/// Caller owns the returned slice.
pub fn formatBytes(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    if (bytes < 1024) return allocator.print("{d} B", .{bytes});
    if (bytes < 1024 * 1024) return allocator.print("{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    if (bytes < 1024 * 1024 * 1024) return allocator.print("{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    return allocator.print("{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
}

/// Format a token count with comma separators (e.g., "1,234,567").
/// Caller owns the returned slice.
pub fn formatTokens(allocator: std.mem.Allocator, tokens: u32) ![]u8 {
    return allocator.print("{d}", .{tokens});
}

/// Format a cost in USD (e.g., "$0.0423").
/// Caller owns the returned slice.
pub fn formatCost(allocator: std.mem.Allocator, cost_usd: f64) ![]u8 {
    return allocator.print("${d:.4}", .{cost_usd});
}

/// Format duration in milliseconds as human-readable.
/// Caller owns the returned slice.
pub fn formatDuration(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    if (ms < 1000) return allocator.print("{d}ms", .{ms});
    if (ms < 60 * 1000) return allocator.print("{d:.1}s", .{@as(f64, @floatFromInt(ms)) / 1000.0});
    if (ms < 60 * 60 * 1000) {
        const mins = @divTrunc(ms, 60 * 1000);
        const secs = @rem(@divTrunc(ms, 1000), 60);
        return allocator.print("{d}m{d}s", .{ mins, secs });
    }
    const hours = @divTrunc(ms, 60 * 60 * 1000);
    const mins = @rem(@divTrunc(ms, 60 * 1000), 60);
    return allocator.print("{d}h{d}m", .{ hours, mins });
}

/// Format a percentage with one decimal place.
/// Caller owns the returned slice.
pub fn formatPercent(allocator: std.mem.Allocator, value: f64) ![]u8 {
    return allocator.print("{d:.1}%", .{value * 100.0});
}

test "formatBytes" {
    const alloc = std.testing.allocator;
    const b1 = try formatBytes(alloc, 500);
    defer alloc.free(b1);
    try std.testing.expectEqualStrings("500 B", b1);

    const b2 = try formatBytes(alloc, 1536);
    defer alloc.free(b2);
    try std.testing.expectEqualStrings("1.5 KB", b2);
}

test "formatDuration" {
    const alloc = std.testing.allocator;
    const d1 = try formatDuration(alloc, 500);
    defer alloc.free(d1);
    try std.testing.expectEqualStrings("500ms", d1);

    const d2 = try formatDuration(alloc, 2500);
    defer alloc.free(d2);
    try std.testing.expectEqualStrings("2.5s", d2);
}

/// Display width of a UTF-8 string: CJK/emoji count 2 terminal columns,
/// ASCII 1, continuation bytes 0 (mirrors the editor's charWidth). Byte
/// counting misaligns every column that contains Chinese text.
pub fn displayWidth(s: []const u8) usize {
    var w: usize = 0;
    for (s) |c| {
        if (c < 0x20) continue;
        if (c < 0x80) {
            w += 1;
        } else if (c >= 0xC0 and c < 0xE0) {
            w += 1;
        } else if (c >= 0xE0) {
            w += 2;
        }
    }
    return w;
}

/// Write `s`, then pad with spaces up to `width` DISPLAY columns (no
/// truncation — an over-wide cell just pushes the column).
pub fn writePadded(writer: *std.Io.Writer, s: []const u8, width: usize) !void {
    try writer.writeAll(s);
    const pad = width -| displayWidth(s);
    for (0..pad) |_| try writer.writeByte(' ');
}

test "displayWidth counts CJK as double columns" {
    try std.testing.expectEqual(@as(usize, 3), displayWidth("abc"));
    try std.testing.expectEqual(@as(usize, 8), displayWidth("中文abcd")); // 2+2+4
}
