/// Memory injection — formats stored memories into a system-prompt block
/// under a token budget (T3.3).
const std = @import("std");
const tokens = @import("../util/tokens.zig");
const embedding = @import("../util/embedding.zig");
const time_mod = @import("../util/time.zig");
const types = @import("types.zig");
const database = @import("../storage/database.zig");
const episodic = @import("episodic.zig");

const max_name = 48;
const max_content = 200;

/// e-decay half-life: memories lose relevance with age; a 30-day-old entry
/// scores e^-1 ≈ 36.8% (DESIGN verification #6).
const decay_tau_ms: i64 = 30 * 24 * 3600 * 1000;

/// Relevance score in (0, 1]: how fresh the memory is.
pub fn decayScore(updated_at: i64, now: i64) f64 {
    const age = @max(0, now - updated_at);
    return @exp(-@as(f64, @floatFromInt(age)) / @as(f64, @floatFromInt(decay_tau_ms)));
}

/// Build a memory block for the system prompt. Returns an owned string, or
/// null when nothing fits. Entries are consumed in the given order (most
/// recent first) until the token budget is spent; at least one entry is
/// always attempted.
/// Built memory block: the text for the system prompt plus how many entries
/// actually fit the budget — the caller displays the count, and it must not
/// claim entries the budget truncated away.
pub const MemoryBlock = struct {
    text: []u8,
    included: usize,
};

/// Context-adaptive budget (T1.2): scales the manual setting by the model's
/// estimated context window — piecewise-linear in log2 space with exact
/// anchors 8K→x0.66 / 32K→x1.0 / 128K→x1.66, clamped flat outside. (A
/// logistic curve was rejected: its asymptotes cannot hit the anchors
/// exactly, and anchor-exactness is what the tests pin down.)
pub fn effectiveBudget(manual: u32, context_window: u32) u32 {
    const base: f64 = @floatFromInt(manual);
    const lw = std.math.log2(@as(f64, @floatFromInt(@max(context_window, 4096))));
    var factor: f64 = undefined;
    if (lw <= 13.0) {
        factor = 0.66; // ≤8K: lean workspace for small contexts
    } else if (lw <= 15.0) {
        const t = (lw - 13.0) / 2.0; // 8K..32K → 0.66..1.0
        factor = 0.66 + t * 0.34;
    } else if (lw <= 17.0) {
        const t = (lw - 15.0) / 2.0; // 32K..128K → 1.0..1.66
        factor = 1.0 + t * 0.66;
    } else {
        factor = 1.66; // ≥128K: recall headroom
    }
    const scaled: u32 = @intFromFloat(base * factor);
    return std.math.clamp(scaled, 200, 8000);
}

pub fn buildMemoryBlock(allocator: std.mem.Allocator, entries: []const types.MemoryEntry, budget_tokens: u32) !?MemoryBlock {
    return buildMemoryBlockAnchored(allocator, entries, budget_tokens, null);
}

/// Same as buildMemoryBlock, but an explicit topic anchor (T1.3): null
/// keeps the legacy "most recently updated entry" proxy; a live-topic
/// vector (mean of recent user turns) re-ranks around what the session is
/// actually about. The anchor is BORROWED — only an internally created one
/// is freed here.
pub fn buildMemoryBlockAnchored(allocator: std.mem.Allocator, entries: []const types.MemoryEntry, budget_tokens: u32, anchor: ?[]const f32) !?MemoryBlock {
    if (entries.len == 0) return null;

    // Rank entries: 0.5 × e-decay freshness + 0.5 × topical similarity to
    // the anchor (the live topic when re-anchoring, else the most recently
    // updated memory — a cheap proxy for "what the user is currently
    // about"). Scores are precomputed so the comparator stays
    // allocation-free.
    const now = time_mod.nowMillis();
    var owned_anchor: ?[]f32 = null;
    defer if (owned_anchor) |v| allocator.free(v);
    const anchor_vec: ?[]const f32 = anchor orelse blk: {
        var anchor_idx: usize = 0;
        for (entries, 0..) |e, i| {
            if (e.updated_at > entries[anchor_idx].updated_at) anchor_idx = i;
        }
        const v = embedding.embed(allocator, entries[anchor_idx].content) catch break :blk null;
        owned_anchor = v;
        break :blk @as([]const f32, v);
    };

    const Rank = struct { idx: usize, score: f64 };
    const ranks = try allocator.alloc(Rank, entries.len);
    defer allocator.free(ranks);
    for (entries, 0..) |e, i| {
        var s: f64 = decayScore(e.updated_at, now);
        if (anchor_vec) |a| {
            if (embedding.embed(allocator, e.content) catch null) |ev| {
                defer allocator.free(ev);
                s = 0.5 * s + 0.5 * @as(f64, embedding.cosine(a, ev));
            }
        }
        ranks[i] = .{ .idx = i, .score = s };
    }
    const byScore = struct {
        fn lessThan(_: void, a: Rank, b: Rank) bool {
            return a.score > b.score;
        }
    };
    std.sort.pdq(Rank, ranks, {}, byScore.lessThan);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    var line_buf: [max_name + max_content + 64]u8 = undefined;
    var used: u32 = 8; // header cost
    var included: usize = 0;

    try writer.writeAll("Relevant memories from previous sessions:\n");
    for (ranks) |r| {
        const e = entries[r.idx];
        const name = e.name[0..utf8Boundary(e.name, max_name)];
        const content = e.content[0..utf8Boundary(e.content, max_content)];
        const line = std.fmt.bufPrint(&line_buf, "- [{s}] {s}: {s}\n", .{
            @tagName(e.mem_type),
            name,
            content,
        }) catch continue;

        const cost = tokens.estimateTokens(line);
        if (used + cost > budget_tokens and included > 0) break;
        try writer.writeAll(line);
        used += cost;
        included += 1;
    }

    if (included == 0) return null;
    var list = aw.toArrayList();
    defer list.deinit(allocator);
    return .{ .text = try allocator.dupe(u8, list.items), .included = included };
}

/// Cap a slice at `max` bytes but never mid-UTF-8-rune: back off to the
/// nearest leading byte (ASCII and 4-byte scripts like CJK survive intact).
pub fn utf8Boundary(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var cut = max;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return cut;
}

/// Derive a content-only id for an extracted memory. Identical content maps
/// to the same id, so re-extracting a repeated statement upserts instead of
/// duplicating the row.
pub fn memoryId(content: []const u8, mem_type: []const u8) [16]u8 {
    var id: [16]u8 = undefined;
    // mem_type is folded in: identical text extracted as two different fact
    // types used to collide on one id and overwrite each other on upsert.
    const h1 = std.hash.Wyhash.hash(0, content) ^ std.hash.Wyhash.hash(0x51ed270b, mem_type);
    const h2 = std.hash.Wyhash.hash(0x9e3779b9, content) ^ std.hash.Wyhash.hash(0x85ebca6b, mem_type);
    @memcpy(id[0..8], std.mem.asBytes(&h1));
    @memcpy(id[8..16], std.mem.asBytes(&h2));
    return id;
}

test "decayScore follows e-halflife" {
    const now: i64 = 100 * 24 * 3600 * 1000;
    // Fresh memory scores ~1.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), decayScore(now, now), 1e-9);
    // 30 days old scores e^-1 ≈ 36.8% (DESIGN verification #6).
    const thirty_days_ago = now - decay_tau_ms;
    try std.testing.expectApproxEqAbs(@as(f64, std.math.exp(-1.0)), decayScore(thirty_days_ago, now), 1e-9);
    // Older is strictly less relevant.
    try std.testing.expect(decayScore(thirty_days_ago, now) < decayScore(now - 1000, now));
}

test "buildMemoryBlock orders by decay freshness" {
    const now = time_mod.nowMillis();
    var entries = [_]types.MemoryEntry{
        .{ .id = @splat(1), .mem_type = .user, .name = "old", .description = "", .content = "OLD_MARKER memory", .access_count = 0, .created_at = 0, .updated_at = now - 60 * 24 * 3600 * 1000 },
        .{ .id = @splat(2), .mem_type = .user, .name = "new", .description = "", .content = "NEW_MARKER memory", .access_count = 0, .created_at = 0, .updated_at = now },
    };
    const block = (try buildMemoryBlock(std.testing.allocator, &entries, 800)).?;
    defer std.testing.allocator.free(block.text);

    const new_pos = std.mem.indexOf(u8, block.text, "NEW_MARKER").?;
    const old_pos = std.mem.indexOf(u8, block.text, "OLD_MARKER").?;
    try std.testing.expect(new_pos < old_pos); // fresh first under a tight budget too
}

test "buildMemoryBlock empty returns null" {
    const block = try buildMemoryBlock(std.testing.allocator, &.{}, 800);
    try std.testing.expect(block == null);
}

test "effectiveBudget anchors and clamps (T1.2)" {
    // Exact anchors at 8K / 32K / 128K with the 1200 default.
    try std.testing.expectEqual(@as(u32, 792), effectiveBudget(1200, 8192));
    try std.testing.expectEqual(@as(u32, 1200), effectiveBudget(1200, 32768));
    try std.testing.expectEqual(@as(u32, 1992), effectiveBudget(1200, 131072));
    // Manual bounds still hold after scaling.
    try std.testing.expectEqual(@as(u32, 200), effectiveBudget(200, 8192)); // floor
    try std.testing.expectEqual(@as(u32, 8000), effectiveBudget(8000, 131072)); // ceiling
    // Monotone in context size.
    try std.testing.expect(effectiveBudget(1200, 16384) <= effectiveBudget(1200, 65536));
}

test "buildMemoryBlockAnchored re-ranks around the live topic (T1.3)" {
    // Two disjoint-topic entries with identical timestamps: with no anchor
    // the tie is arbitrary, with an explicit topic anchor the matching
    // entry must rank FIRST (it gets the 0.5 cosine half-score).
    var entries: [2]types.MemoryEntry = undefined;
    const topics = [2][]const u8{
        "user prefers alpha bravo charlie delta for builds",
        "user stores xray yankee zulu whiskey in vault",
    };
    for (&entries, 0..) |*e, i| {
        e.* = .{
            .id = @splat(@intCast(i)),
            .mem_type = .user,
            .name = "topic",
            .description = "d",
            .content = topics[i],
            .access_count = 0,
            .created_at = 0,
            .updated_at = 1000,
        };
    }
    const anchor = try embedding.embed(std.testing.allocator, "alpha bravo charlie question");
    defer std.testing.allocator.free(anchor);
    const block = (try buildMemoryBlockAnchored(std.testing.allocator, &entries, 800, anchor)).?;
    defer std.testing.allocator.free(block.text);
    try std.testing.expect(std.mem.indexOf(u8, block.text, "alpha bravo charlie") != null);
    // The matching line comes first.
    try std.testing.expect(std.mem.indexOf(u8, block.text, "alpha bravo").? < std.mem.indexOf(u8, block.text, "xray yankee").?);
    // No anchor → legacy behavior must still include both.
    const legacy = (try buildMemoryBlock(std.testing.allocator, &entries, 800)).?;
    defer std.testing.allocator.free(legacy.text);
    try std.testing.expect(std.mem.indexOf(u8, legacy.text, "xray yankee") != null);
}

test "buildMemoryBlock respects budget and includes keyword" {
    var entries: [3]types.MemoryEntry = undefined;
    for (&entries, 0..) |*e, i| {
        e.* = .{
            .id = @splat(@intCast(i)),
            .mem_type = .user,
            .name = "preference",
            .description = "desc",
            .content = "user prefers ZIG_MEMORY_KEYWORD over rust for agents",
            .access_count = 0,
            .created_at = 0,
            .updated_at = 0,
        };
    }

    // Generous budget: all three lines fit.
    const block = (try buildMemoryBlock(std.testing.allocator, &entries, 800)).?;
    defer std.testing.allocator.free(block.text);

    try std.testing.expect(std.mem.indexOf(u8, block.text, "ZIG_MEMORY_KEYWORD") != null);
    try std.testing.expect(std.mem.indexOf(u8, block.text, "Relevant memories") != null);

    // Starved budget: at most the first line, never an empty block.
    const tight = (try buildMemoryBlock(std.testing.allocator, &entries, 20)).?;
    defer std.testing.allocator.free(tight.text);

    try std.testing.expect(std.mem.indexOf(u8, tight.text, "ZIG_MEMORY_KEYWORD") != null);
    const lines = std.mem.count(u8, tight.text, "\n- [");
    try std.testing.expect(lines <= 1);
}

test "end-to-end: store via EpisodicStore, reload, inject" {
    var tmp: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp, "/tmp/ziv_inject_e2e_{d}.db", .{time_mod.nowMillis()}) catch return;
    defer _ = @import("../util/fs_ops.zig").deleteFile(path);

    var db = try database.Database.init(std.testing.allocator, path);
    defer db.deinit();
    try db.runMigrations();

    // Session 1: persist.
    {
        var store = episodic.EpisodicStore.init(std.testing.allocator, &db);
        try store.store(.{
            .id = memoryId("session1", "episodic"),
            .mem_type = .user,
            .name = "E2E_MARKER memory",
            .description = "user_preference",
            .content = "always answer in Chinese, E2E_MARKER",
            .access_count = 0,
            .created_at = time_mod.nowMillis(),
            .updated_at = time_mod.nowMillis(),
        });
    }

    // Session 2: reload and inject.
    var store2 = episodic.EpisodicStore.init(std.testing.allocator, &db);
    const entries = try store2.retrieveRecent(20);
    defer store2.freeEntries(entries);
    try std.testing.expect(entries.len == 1);

    const block = (try buildMemoryBlock(std.testing.allocator, entries, 800)).?;
    defer std.testing.allocator.free(block.text);

    try std.testing.expect(std.mem.indexOf(u8, block.text, "E2E_MARKER") != null);
}
