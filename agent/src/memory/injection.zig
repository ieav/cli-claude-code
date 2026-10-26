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
pub fn buildMemoryBlock(allocator: std.mem.Allocator, entries: []const types.MemoryEntry, budget_tokens: u32) !?[]u8 {
    if (entries.len == 0) return null;

    // Rank entries: 0.5 × e-decay freshness + 0.5 × topical similarity to
    // the most recently updated memory (a cheap proxy for "what the user is
    // currently about"). Scores are precomputed so the comparator stays
    // allocation-free.
    const now = time_mod.nowMillis();
    var anchor_idx: usize = 0;
    for (entries, 0..) |e, i| {
        if (e.updated_at > entries[anchor_idx].updated_at) anchor_idx = i;
    }
    const anchor_vec: ?[]f32 = embedding.embed(allocator, entries[anchor_idx].content) catch null;
    defer if (anchor_vec) |v| allocator.free(v);

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
        const name = e.name[0..@min(e.name.len, max_name)];
        const content = e.content[0..@min(e.content.len, max_content)];
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
    return try allocator.dupe(u8, list.items);
}

/// Derive a content-only id for an extracted memory. Identical content maps
/// to the same id, so re-extracting a repeated statement upserts instead of
/// duplicating the row.
pub fn memoryId(content: []const u8) [16]u8 {
    var id: [16]u8 = undefined;
    const h1 = std.hash.Wyhash.hash(0, content);
    const h2 = std.hash.Wyhash.hash(0x9e3779b9, content);
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
    defer std.testing.allocator.free(block);
    const new_pos = std.mem.indexOf(u8, block, "NEW_MARKER").?;
    const old_pos = std.mem.indexOf(u8, block, "OLD_MARKER").?;
    try std.testing.expect(new_pos < old_pos); // fresh first under a tight budget too
}

test "buildMemoryBlock empty returns null" {
    const block = try buildMemoryBlock(std.testing.allocator, &.{}, 800);
    try std.testing.expect(block == null);
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
    defer std.testing.allocator.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "ZIG_MEMORY_KEYWORD") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Relevant memories") != null);

    // Starved budget: at most the first line, never an empty block.
    const tight = (try buildMemoryBlock(std.testing.allocator, &entries, 20)).?;
    defer std.testing.allocator.free(tight);
    try std.testing.expect(std.mem.indexOf(u8, tight, "ZIG_MEMORY_KEYWORD") != null);
    const lines = std.mem.count(u8, tight, "\n- [");
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
            .id = memoryId("session1"),
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
    defer std.testing.allocator.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "E2E_MARKER") != null);
}
