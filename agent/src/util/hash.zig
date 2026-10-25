/// SHA-256 hashing and file fingerprinting utilities.
const std = @import("std");

/// Compute SHA-256 hash of input data. Returns 32-byte digest.
pub fn sha256(data: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(data);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}

/// Compute SHA-256 and return hex string (64 chars).
/// Caller owns the returned slice.
pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const digest = sha256(data);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    for (digest) |byte| {
        try buf.append(allocator, std.fmt.digitToChar(byte >> 4, .lower));
        try buf.append(allocator, std.fmt.digitToChar(byte & 0x0f, .lower));
    }
    return buf.toOwnedSlice(allocator);
}

/// Short fingerprint — first 16 hex chars of SHA-256 (8 bytes).
/// Caller owns the returned slice.
pub fn fingerprint(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const digest = sha256(data);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(digest[0..8])});
}

/// Compute SHA-256 of a file's contents.
/// Caller owns the returned slice.
pub fn fileSha256Hex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const contents = std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024) catch |err| {
        return err;
    };
    defer allocator.free(contents);
    return sha256Hex(allocator, contents);
}

/// Simple FNV-1a hash for non-cryptographic use (HashMap keys etc.)
pub fn fnv1a(data: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (data) |byte| {
        h ^= byte;
        h *%= 1099511628211;
    }
    return h;
}

test "sha256 known" {
    const digest = sha256("hello");
    // SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    try std.testing.expectEqual(@as(u8, 0x2c), digest[0]);
    try std.testing.expectEqual(@as(u8, 0x24), digest[1]);
}

test "sha256Hex" {
    const alloc = std.testing.allocator;
    const hex = try sha256Hex(alloc, "hello");
    defer alloc.free(hex);
    try std.testing.expectEqual(@as(usize, 64), hex.len);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hex);
}

test "fingerprint" {
    const alloc = std.testing.allocator;
    const fp = try fingerprint(alloc, "hello");
    defer alloc.free(fp);
    try std.testing.expectEqual(@as(usize, 16), fp.len);
}

test "fnv1a" {
    const h = fnv1a("test");
    try std.testing.expect(h != 0);
}
