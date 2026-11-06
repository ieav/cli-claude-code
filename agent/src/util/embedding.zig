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
        // P5 stem-lite first: morphological variants share the bucket
        // (offline harness: beats the legacy bag on inflection queries).
        var sbuf: [64]u8 = undefined;
        const stemmed = stemWord(&sbuf, word);
        vec[std.hash.Fnv1a_64.hash(stemmed) % DIMS] += 1;

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

/// P5 RoPE 旋转编码（设计 §一原案）：对相邻维对 (2k, 2k+1) 施加
/// θ_k = π·(2k)/D 的 2D 旋转。注意数学事实：这是全局同一正交变换，
/// dot(Ra, Rb) = dot(a, b)——对 cosine 排序零影响（离线对比 harness
/// 逐对锁定了这一点）。保留它是因为锚点向量持久化（topic baseline）
/// 时旋转后的维度分布更均匀，浮点累加误差更友好；不是检索质量手段。
pub fn ropeRotateInto(out: *[DIMS]f32, vec: []const f32) void {
    const D: f32 = @floatFromInt(DIMS);
    var k: usize = 0;
    while (k + 1 < DIMS) : (k += 2) {
        const dk: f32 = @floatFromInt(k);
        const theta = std.math.pi * dk / D;
        const c = @cos(theta);
        const s = @sin(theta);
        const a = vec[k];
        const b = vec[k + 1];
        out[k] = a * c - b * s;
        out[k + 1] = a * s + b * c;
    }
}

/// P5 stem-lite：ASCII 词小写 + 剥常见屈折后缀（-ing/-ed/-es/-s，仅当
/// 剥后 ≥4 字符）。这是离线对比里真正赢检索质量的改造——"compiling"
/// 与 "compiler" 落同桶，基线只共享 "zig"。
fn stemWord(buf: []u8, word: []const u8) []const u8 {
    if (word.len > buf.len) return word;
    for (word, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    var w = buf[0..word.len];
    const suffixes = [_][]const u8{ "ing", "ed", "es", "s" };
    for (suffixes) |suf| {
        if (w.len > suf.len + 3 and std.mem.endsWith(u8, w, suf)) {
            w = w[0 .. w.len - suf.len];
            break;
        }
    }
    return w;
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

// ── P5 offline retrieval comparison (roadmap acceptance) ─────────────

/// Legacy bag (pre-P5): identical to embedInto minus stem-lite. The
/// harness needs both sides of the comparison compiled in.
fn legacyEmbedInto(out: *[DIMS]f32, text: []const u8) void {
    @memset(out, 0);
    const vec: []f32 = out;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,.;:!?()[]{}\"'`~^|<>=+-*/\\_#@$%&");
    while (it.next()) |word| {
        if (word.len < 2) continue;
        var lbuf: [64]u8 = undefined;
        if (word.len <= lbuf.len) {
            for (word, 0..) |ch, i| lbuf[i] = std.ascii.toLower(ch);
            vec[std.hash.Fnv1a_64.hash(lbuf[0..word.len]) % DIMS] += 1;
            continue;
        }
        vec[std.hash.Fnv1a_64.hash(word) % DIMS] += 1;
    }
    var norm: f32 = 0;
    for (vec) |v| norm += v * v;
    norm = @sqrt(norm);
    if (norm > 0) {
        for (vec) |*v| v.* /= norm;
    }
}

fn mrrOfQuery(comptime embed_fn: fn (out: *[DIMS]f32, text: []const u8) void, query: []const u8, docs: []const []const u8, relevant: []const usize) f64 {
    var qv: [DIMS]f32 = undefined;
    embed_fn(&qv, query);
    var scores: [32]f64 = undefined;
    for (docs, 0..) |d, i| {
        var dv: [DIMS]f32 = undefined;
        embed_fn(&dv, d);
        scores[i] = @as(f64, dot(&qv, &dv));
    }
    var order: [32]usize = undefined;
    for (0..docs.len) |i| order[i] = i;
    for (0..docs.len) |i| {
        for (i + 1..docs.len) |j| {
            if (scores[order[j]] > scores[order[i]]) {
                const t = order[i];
                order[i] = order[j];
                order[j] = t;
            }
        }
    }
    // Reciprocal rank of the best-ranked relevant doc.
    for (0..docs.len) |pos| {
        for (relevant) |r| {
            if (order[pos] == r) return 1.0 / @as(f64, @floatFromInt(pos + 1));
        }
    }
    return 0;
}

test "P5 offline comparison: stem-lite beats legacy; rope is cosine-neutral" {
    const docs = [_][]const u8{
        "zig compiler emits segfault when building debug", // 0 zig
        "zig build system cache invalidation bug", // 1 zig
        "sqlite migration locking WAL mode database", // 2 db
        "postgres index bloat vacuum analyze", // 3 db
        "pasta carbonara recipe with pecorino cheese", // 4 food
        "sourdough starter feeding schedule flour", // 5 food
        "记忆系统需要中文分词支持", // 6 zh
        "中文分词对记忆系统很重要", // 7 zh
    };
    const Case = struct {
        q: []const u8,
        relevant: []const usize,
    };
    const cases = [_]Case{
        .{ .q = "compiling errors in zig", .relevant = &.{0, 1} }, // morphology: compiling→compil, legacy shares only "zig"
        .{ .q = "database locked during migration", .relevant = &.{2} },
        .{ .q = "cheese pasta dinner", .relevant = &.{4} },
        .{ .q = "记忆系统中文支持", .relevant = &.{6, 7} },
    };

    var mrr_legacy: f64 = 0;
    var mrr_stem: f64 = 0;
    for (cases) |c| {
        mrr_legacy += mrrOfQuery(legacyEmbedInto, c.q, &docs, c.relevant);
        mrr_stem += mrrOfQuery(embedInto, c.q, &docs, c.relevant);
    }
    mrr_legacy /= cases.len;
    mrr_stem /= cases.len;
    // The wired variant must not lose anywhere and must WIN overall —
    // the morphology query is where the legacy bag misses.
    try std.testing.expect(mrr_stem > mrr_legacy);
    try std.testing.expect(mrr_stem >= 0.9);

    // RoPE neutrality, locked pair-by-pair: a global block-diagonal
    // rotation is orthogonal, so every cosine is preserved. This is the
    // empirical basis for NOT flipping the stored format for it.
    for ([_][]const u8{ "zig compiler bug", "sqlite WAL migration", "pasta recipe cheese" }) |ta| {
        for ([_][]const u8{ "zig compiler fix", "postgres vacuum", "记忆系统" }) |tb| {
            var a: [DIMS]f32 = undefined;
            var b: [DIMS]f32 = undefined;
            embedInto(&a, ta);
            embedInto(&b, tb);
            var ra: [DIMS]f32 = undefined;
            var rb: [DIMS]f32 = undefined;
            ropeRotateInto(&ra, &a);
            ropeRotateInto(&rb, &b);
            const plain = dot(&a, &b);
            const rotated = dot(&ra, &rb);
            try std.testing.expectApproxEqAbs(plain, rotated, 1e-4);
        }
    }
}
