/// Mathematical constants that drive Zage's core algorithms.
/// π — circular information coverage
/// e — natural growth limits
/// φ — knowledge condensation ratio

pub const PI: f64 = 3.14159265358979323846;
pub const E: f64 = 2.71828182845904523536;
pub const PHI: f64 = 0.61803398874989484820;
pub const PHI_INVERSE: f64 = 1.61803398874989484820; // 1/φ = (1+√5)/2
pub const PHI_64: u64 = 11400714819323198549; // φ × 2^64 for Fibonacci hashing

test "constants sanity" {
    try std.testing.expectApproxEqAbs(PI, std.math.pi, 1e-10);
    try std.testing.expectApproxEqAbs(E, std.math.e, 1e-10);
    try std.testing.expectApproxEqAbs(PHI, (@sqrt(5.0) - 1.0) / 2.0, 1e-10);
    try std.testing.expectApproxEqAbs(PHI_INVERSE, 1.0 / PHI, 1e-10);
}

const std = @import("std");
