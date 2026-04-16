/// Vector store — stores and searches embeddings using cosine similarity on SQLite BLOBs.

const std = @import("std");

pub const VectorStore = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Serialize f32 slice to bytes for SQLite BLOB storage.
    pub fn serializeEmbedding(allocator: std.mem.Allocator, embedding: []const f32) ![]u8 {
        const bytes = std.mem.sliceAsBytes(embedding);
        return allocator.dupe(u8, bytes);
    }

    /// Deserialize bytes back to f32 slice.
    pub fn deserializeEmbedding(bytes: []const u8) []const f32 {
        const f32_count = bytes.len / @sizeOf(f32);
        const ptr: [*]const f32 = @ptrCast(@alignCast(bytes.ptr));
        return ptr[0..f32_count];
    }

    /// Cosine similarity between two f32 vectors.
    pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
        std.debug.assert(a.len == b.len);
        var dot: f64 = 0;
        var norm_a: f64 = 0;
        var norm_b: f64 = 0;
        for (a, b) |ai, bi| {
            dot += @as(f64, @floatCast(ai)) * @as(f64, @floatCast(bi));
            norm_a += @as(f64, @floatCast(ai)) * @as(f64, @floatCast(ai));
            norm_b += @as(f64, @floatCast(bi)) * @as(f64, @floatCast(bi));
        }
        const denom = @sqrt(norm_a) * @sqrt(norm_b);
        if (denom < 1e-10) return 0;
        return @floatCast(dot / denom);
    }
};

test "VectorStore serialize/deserialize" {
    const alloc = std.testing.allocator;
    const original = &[_]f32{ 1.0, 0.5, -0.3, 0.8 };

    const serialized = try VectorStore.serializeEmbedding(alloc, original);
    defer alloc.free(serialized);

    const deserialized = VectorStore.deserializeEmbedding(serialized);
    try std.testing.expectEqual(@as(usize, 4), deserialized.len);

    for (original, deserialized) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 1e-6);
    }
}

test "VectorStore cosine similarity" {
    const a = &[_]f32{ 1.0, 0.0, 0.0 };
    const b = &[_]f32{ 1.0, 0.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), VectorStore.cosineSimilarity(a, b), 1e-6);

    const c = &[_]f32{ 0.0, 1.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), VectorStore.cosineSimilarity(a, c), 1e-6);

    const d = &[_]f32{ -1.0, 0.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), VectorStore.cosineSimilarity(a, d), 1e-6);
}
