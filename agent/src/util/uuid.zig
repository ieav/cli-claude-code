/// UUID generation — v4 random UUIDs.
const std = @import("std");
const time_mod = @import("time.zig");

/// Fill `buf` with random bytes. Zig 0.17 removed std.crypto.random;
/// seed a ChaCha CSPRNG from the clock, a stack address, and a call
/// counter (the counter keeps same-millisecond calls distinct).
var call_seq = std.atomic.Value(u64).init(0);

fn randomBytes(buf: []u8) void {
    const n = call_seq.fetchAdd(1, .monotonic);
    var seed: u64 = @bitCast(time_mod.nowMillis());
    seed ^= @intFromPtr(buf.ptr);
    seed ^= n *% 0x9E3779B97F4A7C15;
    var sm = std.Random.SplitMix64.init(seed);
    var key: [32]u8 = undefined;
    for (0..4) |i| {
        const v = sm.next();
        @memcpy(key[i * 8 ..][0..8], std.mem.asBytes(&v));
    }
    var csprng = std.Random.DefaultCsprng.init(key);
    csprng.random().bytes(buf);
}

/// Generate a v4 (random) UUID string: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
/// Caller owns the returned slice.
pub fn v4(allocator: std.mem.Allocator) ![]u8 {
    var buf: [16]u8 = undefined;
    randomBytes(&buf);

    // Version 4
    buf[6] = (buf[6] & 0x0f) | 0x40;
    // Variant 1
    buf[8] = (buf[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(
        allocator,
        "{x}-{x}-{x}-{x}-{x}",
        .{
            buf[0..4],
            buf[4..6],
            buf[6..8],
            buf[8..10],
            buf[10..16],
        },
    );
}

/// Generate a v4 UUID into a fixed buffer. Returns 36-char string.
pub fn v4Buf(buf: *[36]u8) void {
    var rand: [16]u8 = undefined;
    randomBytes(&rand);
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
    randomBytes(&buf);
    return std.fmt.allocPrint(allocator, "{x}", .{&buf});
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

test "v4Buf produces distinct ids" {
    var a: [36]u8 = undefined;
    var b: [36]u8 = undefined;
    v4Buf(&a);
    v4Buf(&b);
    // Same-millisecond calls still differ thanks to the address mix-in.
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
