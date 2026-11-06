/// Hash-based hybrid embedding — a cheap, deterministic, dependency-free
/// vector for similarity ranking. Good enough to prefer topically-related
/// memories over unrelated ones; lexical, not semantic (shared substrings
/// rank high, synonyms do not).
///
/// Two regimes, because word-splitting fails half the input:
///  - ASCII words hash as whole words (works: "compiler"/"compile" share
///    the prefix-heavy word hash only when identical — fine for topics).
///  - CJK has no spaces, so the tokenizer returns whole sentences as one
///    "word". The 64-dim word-only hash gave two paraphrased Chinese
///    sentences cosine ≈ 0 — topical re-ranking silently never fired for
///    the user's primary language. Non-ASCII words therefore ALSO hash
///    per-codepoint and adjacent-codepoint bigrams, the fastText-style
///    fallback: overlapping substrings now produce real similarity.
///
/// 256 dims (was 64) to cut hash collisions now that each sentence adds
/// ~2× its char count of features.
const std = @import("std");

pub const DIMS = 256;

/// Zero-allocation core: writes a normalized vector into `out`. The
/// per-prompt injection path embeds up to 1000 candidate rows; a heap
/// vector per row was ~2000 alloc/free pairs per prompt for no benefit.
pub fn embedInto(out: *[DIMS]f32, text: []const u8) void {
    @memset(out, 0);
    const vec: []f32 = out;

    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,.;:!?()[]{}\"'`~^|<>=+-*/\\_#@$%&");
    while (it.next()) |word| {
        if (word.len < 2) continue;
        // Whole-word hash — the only signal the original version had.
        vec[std.hash.Fnv1a_64.hash(word) % DIMS] += 1;

        // CJK/bigram regime: any non-ASCII byte in the word means the word
        // is (probably) an unsegmented CJK run; hash its codepoints.
        const view = std.unicode.Utf8View.init(word) catch continue;
        var cps: [96]u21 = undefined;
        var n: usize = 0;
        var has_non_ascii = false;
        var cit = view.iterator();
        while (cit.nextCodepoint()) |cp| {
            if (cp > 0x7F) has_non_ascii = true;
            if (n < cps.len) {
                cps[n] = cp;
                n += 1;
            }
        }
        if (!has_non_ascii or n < 2) continue;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            vec[std.hash.Fnv1a_64.hash(std.mem.asBytes(&cps[i])) % DIMS] += 0.5;
            if (i + 1 < n) {
                const pair = [2]u21{ cps[i], cps[i + 1] };
                vec[std.hash.Fnv1a_64.hash(std.mem.asBytes(&pair)) % DIMS] += 1.0;
            }
        }
    }

    // L2 normalize so cosine is a plain dot product.
    var norm: f32 = 0;
    for (vec) |v| norm += v * v;
    norm = @sqrt(norm);
    if (norm > 0) {
        for (vec) |*v| v.* /= norm;
    }
}

/// Heap-allocating convenience wrapper for callers that keep the vector
/// (topic baselines, tests). The hot ranking path uses embedInto directly.
pub fn embed(allocator: std.mem.Allocator, text: []const u8) ![]f32 {
    const vec = try allocator.alloc(f32, DIMS);
    errdefer allocator.free(vec);
    embedInto(vec[0..DIMS], text);
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

test "embed makes paraphrased Chinese sentences similar (bigram regime)" {
    const alloc = std.testing.allocator;

    const zh1 = try embed(alloc, "记忆系统需要中文分词支持");
    defer alloc.free(zh1);
    // Shares the substrings 记忆/系统/中文/分词 — different wording, same topic.
    const zh2 = try embed(alloc, "中文分词对记忆系统很重要");
    defer alloc.free(zh2);
    const pasta = try embed(alloc, "pasta recipe with cheese");
    defer alloc.free(pasta);

    const sim_topic = dot(zh1, zh2);
    const sim_far = dot(zh1, pasta);
    // The word-only 64-dim hash scored this pair ≈ 0 (one hash bucket for
    // two unrelated whole-sentence "words"); bigrams must separate them.
    try std.testing.expect(sim_topic > 3 * sim_far + 0.05);
    try std.testing.expect(sim_topic > 0.1);
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
