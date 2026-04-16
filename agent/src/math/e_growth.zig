/// e-based growth control — uses sigmoid, exponential decay, and logistic functions
/// to bound all expansion in the system. Nature's growth limit applied to agent resources.

const std = @import("std");
const constants = @import("constants.zig");

/// Sigmoid function: σ(x) = 1 / (1 + e^(-x))
/// Maps any real to (0, 1). Used for resource pressure scoring, confidence bounds.
pub fn sigmoid(x: f64) f64 {
    // Clamp to avoid overflow in @exp
    const clamped = std.math.clamp(x, -500, 500);
    return 1.0 / (1.0 + @exp(-clamped));
}

/// Exponential decay: value(t) = initial × e^(-λ × t)
/// Used for knowledge relevance, memory access frequency, exploration epsilon.
pub fn expDecay(initial: f64, lambda: f64, t: f64) f64 {
    return initial * @exp(-lambda * t);
}

/// Logistic capacity: computes effective capacity under pressure.
/// As `current` approaches `max`, growth naturally saturates.
/// growth_rate controls how sharply saturation kicks in.
pub fn logisticCap(current: f64, max: f64, growth_rate: f64) f64 {
    const ratio = if (max > 0) current / max else 0;
    const pressure = growth_rate * (ratio - 0.5) * 6.0;
    return max * sigmoid(pressure);
}

/// Exploration epsilon with exponential decay:
/// ε(t) = ε_min + (ε_0 - ε_min) × e^(-rate × t)
/// Starts at ε_0, decays toward ε_min.
pub fn explorationEpsilon(eps_min: f64, eps_0: f64, rate: f64, step: u64) f64 {
    return eps_min + (eps_0 - eps_min) * @exp(-rate * @as(f64, @floatFromInt(step)));
}

/// Retry delay with exponential backoff using e base:
/// delay = min(base × e^(attempt × ln(2)), max_delay)
/// Equivalent to base × 2^attempt but smoother derivation.
pub fn retryDelay(base_ms: u64, attempt: u32, max_delay_ms: u64) u64 {
    const exponent = @as(f64, @floatFromInt(attempt)) * std.math.ln2;
    const raw = @as(f64, @floatFromInt(base_ms)) * @exp(exponent);
    const capped = std.math.clamp(raw, 0, @as(f64, @floatFromInt(max_delay_ms)));
    return @intFromFloat(@round(capped));
}

/// Compute the effective max concurrent tasks given current queue pressure.
/// Uses logistic growth bounded by hardware limit.
pub fn effectiveConcurrency(current_load: usize, hw_threads: usize) usize {
    if (hw_threads == 0) return 1;
    const effective = logisticCap(
        @floatFromInt(current_load),
        @floatFromInt(hw_threads),
        2.0,
    );
    return @max(1, @as(usize, @intFromFloat(@round(effective))));
}

test "sigmoid bounds" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), sigmoid(0), 1e-10);
    try std.testing.expect(sigmoid(100) > 0.99);
    try std.testing.expect(sigmoid(-100) < 0.01);
    try std.testing.expect(sigmoid(1) > 0.5 and sigmoid(1) < 1.0);
    try std.testing.expect(sigmoid(-1) > 0.0 and sigmoid(-1) < 0.5);
}

test "expDecay" {
    const half_life = expDecay(1.0, std.math.ln2, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), half_life, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), expDecay(1.0, 0, 100), 1e-10);
    try std.testing.expect(expDecay(1.0, 1.0, 10) < 0.001);
}

test "logisticCap saturates" {
    const cap = logisticCap(0, 100, 2.0);
    try std.testing.expect(cap > 0);
    // Near max: growth should plateau
    const near_max = logisticCap(99, 100, 2.0);
    const at_max = logisticCap(100, 100, 2.0);
    try std.testing.expect(near_max < 100);
    try std.testing.expect(at_max < 100);
}

test "explorationEpsilon decays" {
    const eps = explorationEpsilon(0.01, 1.0, 0.1, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), eps, 1e-10);
    const eps_late = explorationEpsilon(0.01, 1.0, 0.1, 100);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), eps_late, 0.01);
}

test "retryDelay" {
    try std.testing.expectEqual(@as(u64, 500), retryDelay(500, 0, 60000));
    const d1 = retryDelay(500, 1, 60000);
    try std.testing.expect(d1 >= 900 and d1 <= 1100); // ~1000
    const d5 = retryDelay(500, 10, 60000);
    try std.testing.expect(d5 <= 60000); // capped
}

test "effectiveConcurrency" {
    const c0 = effectiveConcurrency(0, 8);
    try std.testing.expect(c0 >= 1);
    const c_full = effectiveConcurrency(8, 8);
    try std.testing.expect(c_full <= 8);
    const c_over = effectiveConcurrency(16, 8);
    try std.testing.expect(c_over <= 8);
}
