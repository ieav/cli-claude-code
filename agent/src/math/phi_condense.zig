/// φ-based knowledge condensation — the golden ratio (~0.618) determines optimal compression.
/// Fibonacci hashing gives the most uniform key distribution possible.
/// Golden section search finds optima with minimal evaluations.

const std = @import("std");
const constants = @import("constants.zig");

/// Fibonacci hashing — the most uniform hash distribution for integer keys.
/// Uses φ × 2^64 = 11400714819323198549 as multiplier.
/// table_size_log2 must be in [1, 63].
pub fn fibonacciHash(key: u64, table_size_log2: u6) usize {
    if (table_size_log2 == 0) return 0;
    const product = key *% constants.PHI_64;
    // Shift right by (64 - table_size_log2), computed in usize to avoid u6 overflow
    const shift_amt: usize = 64 - @as(usize, table_size_log2);
    return @intCast(product >> @intCast(shift_amt));
}

/// Golden section search — finds the minimum of a unimodal function in [a, b].
/// Each iteration eliminates φ ≈ 61.8% of the remaining interval.
/// Returns the x value that minimizes f(x).
pub fn goldenSectionSearch(
    comptime F: type,
    f: *const fn (F, f64) f64,
    ctx: F,
    a: f64,
    b: f64,
    tolerance: f64,
) f64 {
    const inv_phi = 1.0 / constants.PHI_INVERSE; // ≈ 0.618
    var lo = a;
    var hi = b;
    var c = hi - inv_phi * (hi - lo);
    var d = lo + inv_phi * (hi - lo);

    var iterations: usize = 0;
    const max_iterations = 100; // safety bound

    while ((hi - lo) > tolerance and iterations < max_iterations) : (iterations += 1) {
        if (f(ctx, c) < f(ctx, d)) {
            hi = d;
        } else {
            lo = c;
        }
        c = hi - inv_phi * (hi - lo);
        d = lo + inv_phi * (hi - lo);
    }
    return (lo + hi) / 2.0;
}

/// Compute condensation target count using golden ratio.
/// Each condensation pass reduces to φ ≈ 61.8% of original.
pub fn condensationTarget(original_count: usize) usize {
    if (original_count == 0) return 0;
    const target = @round(@as(f64, @floatFromInt(original_count)) * constants.PHI);
    return @max(1, @as(usize, @intFromFloat(target)));
}

/// Compute condensation target after N iterations:
/// count × φ^n — models repeated compression.
pub fn condensationTargetN(original_count: usize, iterations: usize) usize {
    if (original_count == 0) return 0;
    const factor = std.math.pow(f64, constants.PHI, @as(f64, @floatFromInt(iterations)));
    const target = @round(@as(f64, @floatFromInt(original_count)) * factor);
    return @max(1, @as(usize, @intFromFloat(target)));
}

/// Golden ratio pruning threshold: edges with weight < φ × max_weight are pruned.
pub fn pruningThreshold(max_weight: f64) f64 {
    return max_weight * constants.PHI;
}

/// Optimal dimension after golden ratio compression.
/// e.g., 1536 → 950 (preserving ~61.8% of dimensions).
pub fn compressedDimension(original_dim: usize) usize {
    return condensationTarget(original_dim);
}

test "fibonacciHash distribution" {
    // Hash should distribute keys well
    var counts = [_]usize{0} ** 16;
    for (0..256) |i| {
        const idx = fibonacciHash(@intCast(i), 4); // table_size = 2^4 = 16
        counts[idx] += 1;
    }
    // Each bucket should have roughly 256/16 = 16 entries
    for (counts) |c| {
        try std.testing.expect(c >= 8 and c <= 32); // reasonable spread
    }
}

test "fibonacciHash no collisions for sequential keys in small range" {
    var seen = [_]bool{false} ** 8;
    var unique: usize = 0;
    for (0..8) |i| {
        const idx = fibonacciHash(@intCast(i), 3);
        if (!seen[idx]) {
            seen[idx] = true;
            unique += 1;
        }
    }
    // At least 6 of 8 should be unique (golden ratio hashing is very good)
    try std.testing.expect(unique >= 6);
}

test "goldenSectionSearch finds minimum" {
    const f = struct {
        fn eval(_: void, x: f64) f64 {
            return (x - 3.0) * (x - 3.0); // minimum at x=3
        }
    }.eval;
    const result = goldenSectionSearch(void, f, {}, 0, 10, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result, 1e-4);
}

test "condensationTarget" {
    try std.testing.expectEqual(@as(usize, 618), condensationTarget(1000));
    try std.testing.expectEqual(@as(usize, 62), condensationTarget(100));
    try std.testing.expectEqual(@as(usize, 1), condensationTarget(1));
    try std.testing.expectEqual(@as(usize, 0), condensationTarget(0));
}

test "condensationTargetN repeated application" {
    // 1000 × 0.618^3 ≈ 236
    const result = condensationTargetN(1000, 3);
    try std.testing.expect(result >= 235 and result <= 240);
}

test "pruningThreshold" {
    const t = pruningThreshold(1.0);
    try std.testing.expectApproxEqAbs(constants.PHI, t, 1e-10);
}

test "compressedDimension" {
    try std.testing.expectEqual(@as(usize, 950), compressedDimension(1536));
}
