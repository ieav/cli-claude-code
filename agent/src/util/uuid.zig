/// UUID generation — v4 random UUIDs.
const std = @import("std");

/// Generate a v4 (random) UUID string: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
/// Caller owns the returned slice.
pub fn v4(allocator: std.mem.Allocator) ![]u8 {
    var buf: [16]u8 = undefined;
    std.crypto.random.bytes(&buf);

    // Version 4
    buf[6] = (buf[6] & 0x0f) | 0x40;
    // Variant 1
    buf[8] = (buf[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}-{s}-{s}",
        .{
            std.fmt.fmtSliceHexLower(buf[0..4]),
            std.fmt.fmtSliceHexLower(buf[4..6]),
            std.fmt.fmtSliceHexLower(buf[6..8]),
            std.fmt.fmtSliceHexLower(buf[8..10]),
            std.fmt.fmtSliceHexLower(buf[10..16]),
        },
    );
}

/// Generate a v4 UUID into a fixed buffer. Returns 36-char string.
pub fn v4Buf(buf: *[36]u8) void {
    var rand: [16]u8 = undefined;
    std.crypto.random.bytes(&rand);
    rand[6] = (rand[6] & 0x0f) | 0x40;
    rand[8] = (rand[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var i: usize = 0;
    var j: usize = 0;
    while (i < 16) : (i += 1) {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[j] = '-';
            j += 1;
        }
        buf[j] = hex[rand[i] >> 4];
        buf[j + 1] = hex[rand[i] & 0x0f];
        j += 2;
    }
}

/// Generate a short ID — 8 hex chars from random bytes.
/// Useful for operation IDs, task IDs, etc.
pub fn shortId(allocator: std.mem.Allocator) ![]u8 {
    var buf: [4]u8 = undefined;
    std.crypto.random.bytes(&buf);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&buf)});
}

test "UUID v4 format" {
    const alloc = std.testing.allocator;
    const id = try v4(alloc);
    defer alloc.free(id);
    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expect(id[8] == '-');
    try std.testing.expect(id[13] == '-');
    try std.testing.expect(id[18] == '-');
    try std.testing.expect(id[23] == '-');
    // Version nibble
    try std.testing.expect(id[14] == '4');
}

test "shortId" {
    const alloc = std.testing.allocator;
    const id = try shortId(alloc);
    defer alloc.free(id);
    try std.testing.expectEqual(@as(usize, 8), id.len);
}
