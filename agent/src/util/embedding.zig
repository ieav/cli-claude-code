/// Hash-based bag-of-words embedding — a cheap, deterministic, dependency-
/// free vector for similarity ranking (64 dims). Good enough to prefer
/// topically-related memories over unrelated ones.
const std = @import("std");

pub const DIMS = 64;

/// Embed text as a normalized f32 vector. Caller owns the slice.
pub fn embed(allocator: std.mem.Allocator, text: []const u8) ![]f32 {
    var vec = try allocator.alloc(f32, DIMS);
    errdefer allocator.free(vec);
    @memset(vec, 0);

    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,.;:!?()[]{}\"'`~^|<>=+-*/\\_#@$%&");
    var count: f32 = 0;
    while (it.next()) |word| {
        if (word.len < 2) continue;
        const h = std.hash.Fnv1a_64.hash(word);
        vec[h % DIMS] += 1;
        count += 1;
    }

    // L2 normalize so cosine is a plain dot product.
    var norm: f32 = 0;
    for (vec) |v| norm += v * v;
    norm = @sqrt(norm);
    if (norm > 0) {
        for (vec) |*v| v.* /= norm;
    }
    return vec;
}

test "embed is normalized and topic-sensitive" {
    const alloc = std.testing.allocator;

    const zig1 = try embed(alloc, "zig compiler bug fix");
    defer alloc.free(zig1);
    const zig2 = try embed(alloc, "zig compiler error fix");
    defer alloc.free(zig2);
    const pasta = try embed(alloc, "pasta recipe with cheese");
    defer alloc.free(pasta);

    var norm: f32 = 0;
    for (zig1) |v| norm += v * v;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm, 1e-4);

    const sim_close = std.math.acos(std.math.clamp(dot(zig1, zig2), -1, 1));
    const sim_far = std.math.acos(std.math.clamp(dot(zig1, pasta), -1, 1));
    // Same-topic texts should be far more similar than unrelated ones.
    try std.testing.expect(sim_close < sim_far);
}

fn dot(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

/// Cosine similarity for equal-length vectors (embed outputs are L2-normalized,
/// so this is the dot product).
pub fn cosine(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    return dot(a, b);
}
